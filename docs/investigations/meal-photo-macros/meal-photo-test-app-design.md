# Meal photo macros test app: design sketch

As of 2026-10-13. A standalone iPhone app, separate from Trio, that takes a meal photo and returns a text description plus carbs, protein and fat. Its real job is to be a test bench: the same photo can be run through Apple Foundation Models, a third-party on-device model, or a cloud model with your own key, side by side, and scored against weighed meals. Research notes behind this doc are in `research_notes/Meal photo test app design/`.

## Bottom line

- **Build it as a benchmark, not just a camera app.** No published study shows one model is clearly best at this. The app's comparison and accuracy modes are what answer "which method works".
- **iOS 27 makes most of it one code path.** `LanguageModelSession` with a single `@Generable` `MealEstimate` type can drive Apple's on-device model, Claude (Anthropic's `ClaudeForFoundationModels` package), MLX open models (`MLXLanguageModel`) and Gemini (Firebase AI Logic). OpenAI and OpenRouter need a small REST adapter.
- **Third-party on-device is medium effort, not high risk, in a separate app.** The "high engineering risk" in the Trio report was about a memory kill taking the insulin loop down with it. Here a kill only ends the test app. The ~6 GB per-app memory ceiling is real, and the right models fit under it.
- **Cloud picks:** Opus 5.5, GPT-6 Astra and Gemini 3.1 Pro for best quality; Sonnet 5.5, GPT-6.1 Sol and Gemini 3.8 Flash for cost-effective. A full 50-meal accuracy run across ten cloud configs costs roughly $60.
- **Make the one-line text hint a first-class input.** In published studies it improved accuracy more than switching models.

## 1. App overview and capabilities

The app has four modes. Everything you described is in the first three; the fourth is what makes the comparisons trustworthy.

| Mode | What it does | Photo kept? |
|---|---|---|
| Quick estimate | Take or pick a photo, optional one-line hint, pick a backend, get description + carbs/protein/fat + per-item breakdown, confidence, latency, cost | No, discarded after the run |
| Compare | Run one photo (and hint) through several configured backends at once and show the results side by side | No, unless saved to the test set |
| Backends and settings | Manage API keys (Keychain), pick models per channel, download/delete on-device models, set image size, temperature/effort, prompt version | n/a |
| Test set and evaluation | Store meals with weighed ground truth, batch-run any backends over them (photo-only, photo + hint, hint-only, with repeats), show accuracy metrics, export CSV | Yes, deliberately, so runs can be replayed |

The three channels you asked for, plus one optional fourth:

1. **Apple Foundation Models (on-device).** Zero download, zero API cost, iOS 27 only.
2. **Third-party on-device VLM.** Open models such as Qwen3.5 or Gemma 4, downloaded once and run with MLX.
3. **Cloud, bring your own key.** Anthropic, OpenAI, Google Gemini and OpenRouter.
4. **Suggested extra: hybrid "identify + look up".** Any model lists the foods and estimates grams; Swift looks up each food in USDA FoodData Central and does the macro maths. The best result in the research came from grounding a model in a nutrition database (NutriDish, 5.9 g carb error vs 8.7 g for the plain model), so this is worth testing as its own method.

## 2. Cloud models: which to use

Prices and model IDs are from the official pricing pages and OpenRouter's live model list, fetched 2026-10-13. Per-photo cost assumes a 1024 px JPEG, about 400 prompt tokens, about 300 JSON output tokens, and a guessed ~500 reasoning tokens where reasoning can't be turned off. Log real `usage` to replace the guesses.

| Provider | Best quality | Cost-effective | Structured output |
|---|---|---|---|
| Anthropic | `claude-opus-5-5`, $4 / $20 per M tokens, ~$0.02–0.03 per photo (thinking can't be off; use effort `low`) | `claude-sonnet-5-5`, $2 / $10, ~$0.0065 with thinking off. Cheap floor: `claude-haiku-5-5`, ~$0.0003 | Structured outputs: `output_config.format` with a JSON schema, or a strict tool. No `minimum`/`maximum` in the schema |
| OpenAI | `gpt-6-astra`, $10 / $50, ~$0.056 at `low` reasoning | `gpt-6.1-sol`, $2 / $10, ~$0.011 at `low`. Cheap floor: `gpt-6-luna`, ~$0.0003 | Structured Outputs: `text.format` json_schema with `strict: true` |
| Google Gemini | `gemini-3.1-pro-preview` (preview), $2 / $12, ~$0.013 at thinking `low` | `gemini-3.8-flash`, $0.75 / $3.75, ~$0.005 (price doubles 2027-01-01). Cheap floor: `gemini-3.5-flash-lite`, ~$0.0015 | `responseJsonSchema` / `responseSchema`; numeric min/max allowed. Set a high output limit because thinking counts against it |
| OpenRouter | Best overall is a big-3 model routed through it (e.g. `google/gemini-3.1-pro-preview`, `anthropic/claude-opus-5.5`). Best non-big-3: `qwen/qwen3.8-max-0902`, $2 / $6, ~$0.006 | `qwen/qwen3.8-flash`, $0.15 / $0.47, ~$0.0005. Runner-up: `mistralai/mistral-large-4-0`, ~$0.002 | OpenAI-style `response_format` json_schema; set `provider.require_parameters: true` so it only routes to providers that honour it |

OpenRouter adds no per-token markup; card credit purchases carry a 5.5% fee, and bring-your-own-provider-key routing is free up to $25k a month. One OpenRouter key reaches every model above, which makes it the cheapest way to add breadth.

**Is one model definitely better? No.** Every published food benchmark predates the current October 2026 models.

- OmniFood-Bench (July 2026): GPT-5.1 had the lowest macro error in all four food categories (49% on homemade meals vs 61% Claude Sonnet 4, 114% Gemini 3 Flash).
- ACETADA (2025): GPT-4.1 had the lowest carb error (20.4 g); Claude 3.7 Sonnet was nearly tied on calories and best on fat; Gemini 2.5 Pro was worst.
- Soyer 2026 (small T1D study): Gemini 3 Pro had the lowest photo-only carb error (6.55 g).
- Overall: OpenAI most consistently strong, Claude a close second, Gemini swings by version. Portion size dominates every model's error, and the text hint helps more than the model choice.

**Starting set for the app:** Opus 5.5, Sonnet 5.5, GPT-6 Astra, GPT-6.1 Sol, Gemini 3.1 Pro, Gemini 3.8 Flash, plus Qwen3.8 Max and Qwen3.8 Flash via OpenRouter. A 50-meal set × 3 input modes × 3 repeats is 450 calls per config, about $60 for all eight, or under $15 without Astra and Opus.

## 3. Third-party on-device: the engineering picture

### Is the ~6 GB limit right?

Yes, roughly, and it is a developer measurement, not an Apple-published number.

- **With the `com.apple.developer.kernel.increased-memory-limit` entitlement:** about 6,144 MB per app, measured on an 8 GB iPhone 16 Pro Max, an 8 GB 15 Pro Max and a 12 GB 17 Pro Max. More RAM in the phone does not raise it. `extended-virtual-addressing` made no difference in that test.
- **Without the entitlement:** about 3.3–3.5 GB on 8 GB phones. A Qwen3.5-4B run on a 6 GB iPhone 14 Pro without it was killed at about 3 GB.
- **What counts:** the process "footprint", which on Apple silicon includes GPU/Metal buffers. MLX's GPU buffer cache counts, so set it low (`Memory.cacheLimit = 20 MB`, as Apple's example does). Memory-mapped weights only count once they become dirty.
- **The 2.5–4 GB figure is download size, not the limit.** What has to fit under ~6 GB is weights + vision-encoder activations + KV cache + MLX cache + the app itself. Gemma 4 E2B 4-bit peaked at 3.5 GiB with one photo on an iPhone 16 Pro.
- **Image size causes the spikes.** Qwen3.5-2B survived a 256 px image and was killed at 448 px on a 6 GB phone without the entitlement; Gemma 4 with three 720p images hit 5.97 GB. One image per request, long edge ~768 px, fixes most of this.
- **Account:** a paid Apple Developer account is the reliable way to get the entitlement. A Personal Team build from Xcode reportedly also gets ~6 GB, but that is one user report.

### Models that fit

| Model | MLX repo | Download | Peak RAM | Notes |
|---|---|---|---|---|
| Qwen3.5-4B | `mlx-community/Qwen3.5-4B-4bit` | 3.03 GB | ~4.2–4.8 GB (estimate) | Strongest that fits. Thinks by default: turn thinking off for JSON |
| Qwen3.5-2B | `mlx-community/Qwen3.5-2B-4bit` | 1.72 GB | ~2.9 GB measured (iPhone 14 Pro, 256 px) | Same code path as the 4B; speed baseline |
| Gemma 4 E2B | `mlx-community/gemma-4-e2b-it-4bit` | 3.55 GB | 3.5 GiB measured (iPhone 16 Pro) | Only model with a measured photo run: ~5.5 s per photo. Repo includes an unused audio tower |
| Qwen3-VL-4B | `mlx-community/Qwen3-VL-4B-Instruct-4bit` | 3.09 GB | ~4.3–4.9 GB (estimate) | Non-thinking control; bigger KV cache |
| LFM2.5-VL-3B | `LiquidAI/LFM2.5-VL-3B-MLX-4bit` | 2.37 GB | ~3.2–3.8 GB (estimate) | Newest small option (Aug 2026); custom licence, fine for personal use |
| MiniCPM-V 4.6 | `ggml-org/MiniCPM-V-4.6-GGUF` | 1.26 GB | ~2–2.6 GB (estimate) | llama.cpp only, not MLX |
| boba-0.8b-food | `Doses-AI/boba-0.8b-food-GGUF` | 0.73 GB | small | Qwen3.5-0.8B fine-tuned on Nutrition5k to output per-ingredient JSON. Interesting later, via llama.cpp |

All Apache-2.0 except LFM (custom licence). Skip Gemma 4 E4B (5.15 GB, over the ceiling with an image), FastVLM (research-only licence), Phi-4-multimodal (11 GB) and Moondream 3. No small model has a published food or macro benchmark, so your test set will be the first data.

**Expected speed:** about 4–6 s end to end per photo on a Pro iPhone for a short answer, likely 6–9 s for a JSON breakdown. Sustained runs slow down as the phone heats (+40% over five back-to-back photos in one test), so leave a cool-down between eval runs and log `ProcessInfo.thermalState`.

### Runtime

**MLX Swift (`ml-explore/mlx-swift-lm` 3.32.3)** is the clear pick. It is pure Swift Package Manager, downloads from Hugging Face at runtime, takes an image directly (`UserInput(prompt:images:)`), and registers Gemma 4, Qwen3.5, Qwen3-VL, LFM2-VL and SmolVLM. It has two routes to guaranteed JSON:

- `MLXGuidedGeneration`: JSON Schema-constrained decoding (xgrammar). Blocking call, run it off the main actor.
- `MLXFoundationModels` / `MLXLanguageModel` (iOS 27 SDK): runs an MLX model behind Apple's `LanguageModelSession` with `.vision` and `.guidedGeneration`, so the same `@Generable MealEstimate` works for Apple's model and the MLX model.

Neither route has a published example combining an image with constrained output, so verify that first. The fallback is a JSON-only prompt plus tolerant parsing. llama.cpp (prebuilt XCFramework with multimodal) is the second runtime if you want MiniCPM-V or the fine-tuned food model; schema-to-grammar conversion there is DIY. Google's LiteRT-LM Swift API is still Early Preview.

**Starter template:** Apple's `mlx-swift-examples` → `Applications/MLXChatExample` (MIT). It already has SwiftUI, PhotosPicker, EXIF handling, a 1024 px resize, Hugging Face download and a low cache limit. `JaviChulvi/hermit` is a good read-only reference for the entitlement, memory monitor and device benchmark harness (it has no licence, so don't copy code).

### Components and effort

| Component | Effort | Notes |
|---|---|---|
| SPM setup (mlx-swift-lm, swift-huggingface 1.0, swift-transformers) + entitlement | Small | MLX does not run in the Simulator: test on the phone |
| Model catalog + downloader | Medium | Pinned revisions, Application Support (excluded from backup), Wi-Fi only, progress, resume (built into swift-huggingface), delete |
| Load/unload lifecycle | Medium | One model resident; check `os_proc_available_memory()` before loading; drop the container + `Memory.clearCache()` to unload; unload on background and memory warning |
| Image preprocessing | Small | Fix orientation, long edge ~768 px, one image |
| Prompt + structured output | Medium, riskiest | Guided generation with an image is unverified; Qwen3.5 thinking must be disabled |
| Instrumentation | Small | Load time, time to first token, total time, peak memory, thermal state |

Roughly half a day to a first photo-to-text demo from the template, and two to four days to a robust multi-model backend.

## 4. Apple Foundation Models: implementation notes

- **Two different models depending on phone.** iOS 27 ships "AFM 3 Core" (3B) on iPhone 15 Pro and 16, and "AFM 3 Core Advanced" (20B sparse) on iPhone Air and 17 Pro. In one tool-calling test, task completion was 60% on Core vs 98% on Advanced. Read `SystemLanguageModel.variant` and record it with every result; this may matter more than anything else on the Apple channel.
- **Image input:** `Attachment(photo).label("meal")` inside the `respond` prompt block. Check `model.capabilities.contains(.vision)` first. Apple scales images itself; an image costs roughly 200–320 tokens (not documented, log `usage`). Context is 4,096 tokens on Core and reportedly 8,192 on Advanced; read `contextSize` at runtime.
- **Structured output:** `@Generable` with `@Guide(.range(...))` on numbers, `.maximumCount` on arrays, a `Confidence` enum. Use `GenerationOptions(samplingMode: .greedy)` for repeatable answers. Sum the per-item values in Swift rather than trusting the model's totals.
- **Errors to catch (Xcode 27 names):** `LanguageModelError.guardrailViolation`, `.refusal`, `.contextSizeExceeded`, `.unsupportedCapability`; `SystemLanguageModel.Error.assetsUnavailable`. The permissive guardrail mode does not apply to `@Generable` output.
- **Built-in tools:** `BarcodeReaderTool()` and `OCRTool()` can read a packaged food's barcode or nutrition label in the same call. A custom USDA lookup tool is possible, but tool loops are weak on the 3B Core model, so do lookups in Swift instead.
- **No fine-tuning:** custom adapters are discontinued in iOS 27, so the Apple model can only be steered with prompts and tools.
- **Private Cloud Compute** accepts images (32K context), but the entitlement requires the App Store Small Business Program. Skip it for a personal app.
- **Tooling:** the `#Playground` macro shows token counts while iterating on prompts; the Instruments "Foundation Models" template shows time to first token and tokens per second. On a Mac running macOS 27, `fm respond --image meal.jpg --schema s.json` runs the same on-device model from the command line, which is handy for batch runs (your Mac is on macOS 26.7.1 and would need the upgrade).

Sketch, written against the iOS 27 docs and not yet compiled:

```swift
import FoundationModels

@Generable enum Confidence: String { case low, medium, high }

@Generable struct FoodItem {
    var name: String
    @Guide(description: "Estimated portion in grams", .range(1...1500)) var portionGrams: Int
    @Guide(.range(0...400)) var carbsGrams: Int
    @Guide(.range(0...300)) var proteinGrams: Int
    @Guide(.range(0...300)) var fatGrams: Int
}

@Generable(description: "Nutrition estimate for one meal photo")
struct MealEstimate {
    @Guide(description: "One short sentence describing the meal") var description: String
    @Guide(.maximumCount(8)) var items: [FoodItem]
    var confidence: Confidence
}

func estimateMeal(_ photo: UIImage, hint: String?, model: some LanguageModel = SystemLanguageModel.default) async throws -> MealEstimate {
    let session = LanguageModelSession(model: model, instructions: "You estimate macronutrients from meal photos.")
    let response = try await session.respond(generating: MealEstimate.self, options: GenerationOptions(samplingMode: .greedy)) {
        "List each food with an estimated portion, then grams of carbohydrate, protein and fat."
        if let hint { "The person eating it says: \(hint)" }
        Attachment(photo).label("meal")
    }
    return response.content
}
// Same function, other backends: ClaudeLanguageModel(name: .sonnet5_5, auth: .apiKey(k)) · MLXLanguageModel(...) · Firebase geminiLanguageModel(name: "gemini-3.8-flash")
```

## 5. Measuring accuracy

### Ground truth

- **Your own weighed meals (the main set).** Tare the plate, add one component at a time and record each weight; track cooking oil separately; for batch recipes weigh the whole cooked batch and scale. Compute macros from USDA FoodData Central (free API key; nutrient IDs: protein 1003, fat 1004, carbs 1005), preferring Foundation Foods, then SR Legacy. Tag each meal A (all weighed), B (includes label values) or C (restaurant nutrition); headline results come from A and B.
- **Photo protocol.** A natural ~45° shot from your seat plus an overhead shot; normal cutlery for scale (a reference card didn't help in a 2026 study); scale display out of frame.
- **Hint protocol.** Write the one-line hint at capture time, before seeing any model output, and without grams you only know from weighing. Run every meal three ways: photo only, photo + hint, hint only.
- **Public datasets for a quick offline benchmark:**
  - Nutrition5k test split (CC BY 4.0, 507 dishes, ~200 MB, plain HTTPS download). Many plates are tiny (median 15.4 g carbs), so filter to ≥10 g carbs (~320 dishes) or report grams only. Overhead cafeteria photos.
  - ACETADA (CC BY-NC 4.0, 806 smartphone photos of meals weighed to 0.1 g). The most realistic public set.
  - Avoid MM-Food-100K and anything built from it: its labels were generated by GPT-4o.

### Metrics

- Mean absolute error in grams per macro, with a bootstrap 95% confidence interval.
- Bias (mean signed error): does it systematically over- or under-estimate?
- Share of meals within ±10 g and ±20 g of carbs.
- Percentage error only on meals with at least 10 g of truth.
- Fat + protein calorie error, since that drives Trio's FPUs.
- Run-to-run spread: 3 repeats per photo, within-photo standard deviation.
- Parse failures and refusals counted as failures.
- Latency (cold and warm for on-device), peak memory, tokens and cost.
- Model comparisons: paired Wilcoxon signed-rank on per-meal absolute errors; with several models, Friedman then pairwise Wilcoxon with Holm correction. Resample whole meals, not runs.

### How many meals

| To detect | Meals |
|---|---|
| A big gap (≥5 g), e.g. frontier cloud vs a 2B on-device model | 30–40 |
| A 4 g difference between two models | ~35, or ~58 across ~10 model pairs |
| A 3 g difference across 5–6 models | 60–100 |
| A 1–2 g difference | Treat as a tie |

Collect in waves: after ~30 meals, measure the real spread and re-plan.

### Where to run it

- **Cloud models:** a Mac harness is a valid stand-in if it sends exactly the same image bytes and prompt as the phone.
- **Open on-device models:** run the exact quantized build at the phone's input resolution on the Mac with MLX for accuracy; latency and memory must be measured on the iPhone.
- **Apple's model:** macOS 27's `fm` CLI uses the same on-device model, but match the 27.x point release on both devices and confirm on 15–20 meals on the phone. The Mac's model variant may also differ from your phone's.

## 6. How to build it

### Structure

- **`MealLabKit` (Swift package):** the `MealEstimate` schema, prompt templates (versioned by hash), the backend protocol and adapters, image preprocessing, metrics. Shared by the app and a CLI.
- **iOS app (SwiftUI, iOS 27):** capture, results, compare, settings, test set, eval dashboard (Swift Charts).
- **macOS CLI (optional):** batch-runs the cloud backends and the MLX models over Nutrition5k, ACETADA or your exported test set.

### Backend abstraction

```swift
protocol MealEstimator {
    var id: BackendID { get }             // channel + model id + params hash
    func estimate(_ input: EstimationInput) async throws -> EstimationResult
}
// EstimationInput: JPEG bytes (preprocessed once, hashed), optional hint, mode (photo / photo+hint / hint-only), prompt version
// EstimationResult: MealEstimate, raw response, latency, TTFT, tokens, cost, peak memory, model variant
```

| Adapter | Covers | Built on |
|---|---|---|
| `FoundationModelsEstimator` | Apple on-device, Claude, MLX models, Gemini | `LanguageModelSession` + `@Generable`; swap the `LanguageModel` (`SystemLanguageModel`, `ClaudeLanguageModel`, `MLXLanguageModel`, Firebase Gemini) |
| `OpenAICompatibleEstimator` | OpenAI, OpenRouter (and Gemini's OpenAI-compatible endpoint if Firebase is too heavy) | URLSession + JSON-schema `response_format` |
| `MLXDirectEstimator` | Fallback if `MLXLanguageModel` + image + `@Generable` doesn't work | `MLXGuidedGeneration` or prompt + tolerant JSON parse |
| `HybridLookupEstimator` | Identify + USDA lookup method | Any estimator for items and grams, then FoodData Central |

Every adapter returns the same `MealEstimate`, so results are directly comparable. The Claude and Gemini paths through `LanguageModelSession` are newly released and unverified for image attachments, so keep the REST adapter as a fallback for them too.

### Data model (SwiftData or SQLite)

- `Meal`: date, quality tier, weighed components, ground-truth macros, hint, image hashes.
- `Image`: hash, preprocessed JPEG, angle.
- `Backend`: channel, model ID, runtime, quantization, parameters, OS build, Apple model variant.
- `Run`: meal, backend, input mode, prompt hash, repeat index, raw response, parsed values, latency, tokens, cost, status.
- Runs are unique on (image, mode, prompt, backend, params, repeat), so re-running a batch resumes instead of double-counting.
- Export three CSVs: one row per run, one per meal × backend, and a summary.

### Screens

1. Capture: camera or photo picker, hint field, backend picker (or "compare all").
2. Result: description, totals, per-item table, confidence, latency/cost, "save to test set".
3. Compare: one column per backend, differences highlighted.
4. Backends: API keys, model lists, on-device model downloads with size and status.
5. Test set: meals list, ground-truth entry with USDA search, photo pair.
6. Evaluation: pick backends × modes × repeats, run, then a dashboard of error, bias, hit rates and spread per backend.

### Suggested phases

1. **Apple FM + Claude**, quick estimate only. Proves the schema and prompt on the phone in a day.
2. **Compare mode + OpenAI-compatible adapter**, adding OpenAI, Gemini and OpenRouter.
3. **MLX on-device**: downloader, lifecycle, Qwen3.5-2B first, then Qwen3.5-4B and Gemma 4 E2B.
4. **Test set + evaluation**: ground-truth entry, batch runs, metrics, CSV. Start the Nutrition5k benchmark on the Mac in parallel.
5. **Extras**: hybrid USDA lookup, barcode/label tools, llama.cpp with the fine-tuned food model.

## 7. Other suggestions

- **Let the test set drive model choice.** Cloud picks above are informed guesses; your weighed meals will settle it for your food.
- **Record the Apple model variant.** A 15 Pro and a 17 Pro run different Apple models, so results don't transfer between phones.
- **Always run with and without the hint.** If the hint closes most of the gap, the UX question becomes "how do I make typing a hint effortless" (dictation, suggested phrases) rather than "which model".
- **Keep photos only in the test set.** Quick and compare modes discard the photo, matching the Trio idea; evaluation needs stored photos to replay runs against new models and prompts.
- **Log the AI value next to the value you'd actually use.** Even without weighing, that delta across everyday meals is useful data.

## Open questions

- Does the iOS 27 `MLXLanguageModel` accept an image together with `@Generable` output? Verify first.
- Do the Claude and Gemini `LanguageModelSession` packages handle image attachments end to end? (Claude's package source says yes; Gemini's is unverified.)
- Real image token cost and context size on your phone's Apple model variant.
- Real peak memory and latency of Qwen3.5-4B on your phone.
