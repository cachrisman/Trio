# Third-party on-device VLMs for meal-photo macro estimation in Trio (vs. cloud baseline), as of October 2026

Scope: VLMs and runtimes that are not Apple frameworks (i.e., not Foundation Models / Apple Intelligence), that run fully on an iPhone 15 Pro or newer (8 GB+ RAM) inside a Swift app, for "meal photo -> description + carbs/protein/fat grams". Cloud bring-your-own-key (Claude/GPT/Gemini) is a comparison baseline only. Research date: 2026-10-13. Every benchmark is labelled with its date. Where a source is secondary, community, or marketing, it is flagged.

## 1. Runtimes: which are mature for VLMs on iOS in 2026 (MLX Swift, Core ML, llama.cpp/mtmd, ExecuTorch, MLC LLM, LiteRT-LM)?

### Takeaway
MLX Swift (`ml-explore/mlx-swift-lm`, MIT) is the most mature Swift-native VLM path in October 2026. It registers 22 VLM architectures, including Qwen3-VL, Qwen3.5, Gemma 4, FastVLM, SmolVLM, and LFM2-VL, and there are documented real-iPhone multimodal runs. llama.cpp is a credible second option because its prebuilt XCFramework now includes the `mtmd` multimodal library. Google's LiteRT-LM has the best published iPhone numbers (Gemma 4 E2B), but its Swift API is "Early Preview". ExecuTorch and MLC LLM look immature for VLMs on iOS. I found no evidence of a maintained Core ML conversion path for modern VLMs.

### Cited Findings
- **MLX Swift / mlx-swift-lm.** The package's MLXVLM `VLMTypeRegistry` registers these model types: paligemma, qwen2_vl, qwen2_5_vl, qwen3_vl, qwen3_vl_moe, qwen3_5, qwen3_5_moe, qwen3_8, qwen3_8_moe, idefics3, gemma3, gemma4, gemma4_unified, smolvlm, fastvlm (alias llava_qwen2), pixtral, mistral3, lfm2_vl, glm_ocr, muse_glimmer. `gemma3n` is **not** registered. — [mlx-swift-lm VLMModelFactory.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXVLM/VLMModelFactory.swift)
- Pre-configured small VLM IDs in that registry include `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit`, `mlx-community/Qwen3-VL-4B-Instruct-8bit`, `mlx-community/gemma-4-e2b-it-4bit`, `mlx-community/gemma-4-e4b-it-4bit`, `mlx-community/gemma-3-4b-it-qat-4bit`, `HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx`, `mlx-community/FastVLM-0.5B-bf16`, and `mlx-community/Qwen2.5-VL-3B-Instruct-4bit`. LFM2/LFM2.5-VL-1.6B-4bit and Ministral-3-3B are defined but not in the default list. — [mlx-swift-lm VLMModelFactory.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXVLM/VLMModelFactory.swift)
- mlx-swift-lm is MIT-licensed. — [mlx-swift-lm GitHub](https://github.com/ml-explore/mlx-swift-lm)
- **Real-iPhone MLX VLM run (September 2026):** Gemma 4 E2B 4-bit through mlx-swift-lm (MLX 0.31.4) on an **iPhone 16 Pro**, iOS 26.7, signed Release build with the increased-memory-limit entitlement. Median photo response time was 5.45 s at cache=0, for 65-token photo responses. Latency rose from 4.12 s to 5.80 s as the phone heated to the "serious" thermal state. Peak MLX allocation was 3,509.6 MiB for photos and 2,996.8 MiB for text. No jetsam was observed, but real OS memory pressure was not tested. The author notes this "was not an iPhone 15 Pro test". This is a single developer's study and is not peer reviewed. — [hermit issue #2](https://github.com/JaviChulvi/hermit/issues/2)
- A June 2026 developer report ran Gemma 4 multimodal through mlx-swift-lm (PR #343) on iPhone 16 Pro Max and iPhone 17 Pro Max. The model loaded at about 4.4 GB resident. Jetsam was avoided only after cutting the MLX GPU buffer cache from 512 MB to 64 MB. — [Apple Developer Forums thread 834805](https://developer.apple.com/forums/thread/834805)
- **MLX text-LLM iPhone throughput (Feb 2026), for scale.** On an iPhone 17 Pro (A19 Pro, 12 GB, iOS 26.3 RC), 4-bit decode ran at 37–62 tok/s for 0.6B–1.7B text models: Qwen3 1.7B at 39.5 tok/s with 360 ms TTFT, and Gemma 3 1B QAT at 37.1 tok/s. The author says Qwen3 4B and Llama 3.2 3B "did not fit" within the jetsam limits they assumed. No vision models were tested, and the figures are raw TokenIterator throughput, which the author estimates is 10–15% above end-to-end. — [Ricky Takkar, "How Fast Are On-Device LLMs on iPhone 17 Pro and iPad Pro?"](https://rickytakkar.com/blog_russet_mlx_benchmark.html)
- **llama.cpp / ggml with mtmd.** Each llama.cpp release publishes a prebuilt `llama.xcframework` with iOS device and simulator slices, built with Metal and including the mtmd multimodal library. You import it in Swift with no bridging header. Vision models need the GGUF plus a matching `mmproj-*.gguf`, and the model file must be on disk uncompressed because llama.cpp memory-maps it. The minimum target is iOS 16.4+ per Liquid AI's guide, while the `mattt/llama.swift` wrapper says iOS 16.0+. — [Liquid AI docs: llama.cpp mobile](https://docs.liquid.ai/deployment/on-device/llama-cpp/mobile); [mattt/llama.swift](https://github.com/mattt/llama.swift)
- A llama.cpp commit, "build: include libmtmd in Apple XCFramework", added an opt-in `LLAMA_BUILD_MTMD` CMake option so `build-xcframework.sh` links `libmtmd.a`. The commit author says it was tested on iPhone device, simulator, macOS, and visionOS slices. That claim is not independently verified. — [semanticdiff view of llama.cpp commit e12a012](https://app.semanticdiff.com/gh/ggml-org/llama.cpp/commit/e12a0128ab0be91d500d25d18db05067d3f7b4e8)
- **Google LiteRT-LM** (doc last updated 2026-10-06). The Swift API is marked "Early Preview". On iPhone 17 Pro, Gemma-4-E2B (2.58 GB model file) ran as follows. GPU: 2,878 tk/s prefill, 56 tk/s decode, 0.3 s TTFT, 1,450 MB peak CPU memory. CPU: 532 tk/s prefill, 25 tk/s decode, 1.9 s TTFT, 607 MB. Gemma-4-E4B (3,654 MB) decoded at 25 tk/s on GPU and 10 tk/s on CPU. There are no Gemma 3n iPhone rows. The page does not explicitly confirm image input for chat LLMs on iOS, and the "peak CPU memory" column likely excludes GPU-resident weights (my inference). — [LiteRT-LM overview](https://developers.google.com/edge/litert-lm/overview)
- **ExecuTorch.** The iOS demo app supports LLaVA 1.5 via XNNPACK. The 0.7 docs list Llama, Qwen3, Phi4-mini and "Llava multimodal" as supported. I found no iOS demo running Gemma 3 vision. — [ExecuTorch iOS demo docs 0.7](https://docs.pytorch.org/executorch/0.7/llm/llama-demo-ios.html)
- **MLC LLM.** The iOS SDK docs describe a text chat app that downloads pre-converted weights from Hugging Face. I found no documentation of image input. — [MLC LLM iOS SDK](https://llm.mlc.ai/docs/deploy/ios.html)
- **FastVLM.** Apple's repo ships a demo iOS app and Apple-Silicon checkpoints: 0.5B fp16, 1.5B int8, 7B int4, with a `model_export` path for other quantizations. — [apple/ml-fastvlm](https://github.com/apple/ml-fastvlm)

### Inferences
- For a Swift app that wants Qwen3-VL, Qwen3.5, or Gemma 4 vision on iPhone today, mlx-swift-lm is the lowest-friction choice. It is pure Swift Package Manager, MIT-licensed, has an existing model registry, and loads Hugging Face models. llama.cpp/mtmd is a reasonable fallback with a C API, and its mmap'd weights may behave better under memory pressure than MLX's GPU allocations. I have not verified that difference.
- A conservative baseline for a 2B-class 4-bit VLM on iPhone 16 Pro is roughly 4–6 s per photo for a short answer, with about 3–3.5 GB peak MLX memory (hermit). A structured "description + 3 macro numbers" JSON answer is short, so decode speed matters less than image prefill and model load time.
- Cold model load time is not reported in any source I found. With a 2.5–4 GB model loaded per use, it could add several seconds. This must be measured.
- Integrating any of these into Trio adds a large native dependency: MLX's Metal kernels or the llama.cpp XCFramework. It also adds build complexity for users who build from source.

### Gaps
- No published end-to-end iPhone 15 Pro measurement of any VLM. The 15 Pro has 8 GB of RAM and an A17 Pro, and is the weakest device in the target set.
- No source for Qwen3-VL-2B/4B or Qwen3.5-2B/4B image latency on iPhone via MLX Swift.
- No source on the state of Core ML (coremltools) conversion of modern VLMs such as Qwen3-VL or Gemma 4. I found nothing indicating it is a maintained path.
- I could not confirm that LiteRT-LM's iOS Swift API accepts image input in practice.

## 2. Candidate models: parameters, quantized size, RAM, latency, and on-device viability

### Takeaway
The realistic on-device candidates in October 2026 are 2–4B-class open VLMs: **Gemma 4 E2B/E4B** (Apache 2.0, April 2026), **Qwen3.5-2B/4B** (Apache 2.0, about March 2026, native vision), **Qwen3-VL-2B/4B** (Apache 2.0), and the tiny **SmolVLM2-500M** and **FastVLM-0.5B**. FastVLM is research-only licensed (see Q8). Models of 8B and up are too big for the roughly 6 GB per-process ceiling once inference memory is added. Those include MiniCPM-V 4.5 (about 8.7B), Qwen3-VL-8B, Qwen3.5-9B, and Llama 3.2 Vision 11B. The small models' vision-language scores are well below frontier models, and none has been benchmarked on macronutrient estimation.

### Cited Findings
- **Gemma 4** was released 2026-04-02 under Apache 2.0, the first Gemma generation under a standard OSI license. E2B has about 2.3B effective parameters and E4B about 4.5B effective. Both accept images and audio, have 128K context, and target phones. One source reports MMMU-Pro of 52.6% for E4B and 44.2% for E2B. That figure comes from secondary sources and needs verifying against Google's model card. One secondary source (Emelia) gives conflicting size figures and looks erroneous. — [The Decoder](https://the-decoder.com/googles-gemma-4-is-now-available-with-apache-2-0-licensing-for-the-first-time/); [NYU Shanghai RITS](https://rits.shanghai.nyu.edu/ai/google-releases-gemma-4-frontier-open-models-under-apache-2-0/); [TechWyse](https://www.techwyse.com/news/ai-search/google-deepmind-gemma-4-open-models-apache-2-0-release)
- Gemma 4 E2B on iPhone 17 Pro via LiteRT-LM: 2.58 GB model file, 0.3 s TTFT on GPU, 56 tk/s decode. E4B: 3.65 GB, 25 tk/s GPU decode. These are text-prompt benchmarks, not image prefill. — [LiteRT-LM overview](https://developers.google.com/edge/litert-lm/overview)
- Gemma 4 E2B 4-bit via MLX Swift on iPhone 16 Pro: about 5.5 s median per photo response and 3.5 GiB peak MLX allocation (September 2026). — [hermit issue #2](https://github.com/JaviChulvi/hermit/issues/2)
- **Qwen3.5 small series:** dense 0.8B, 2B, 4B and 9B models released about 2026-03-02 (one directory says 2026-02-28). They are Apache 2.0, with vision built into the base model (no separate "-VL" variant) and 262K context. Reported MMMU-Pro scores: 9B 69.2%, 4B 65.4%, 0.8B 25.8%, against Qwen3-VL-8B at 56.6% and Qwen3-VL-4B at 52.0%. One third-party listing claims Alibaba scopes intended use to prototyping and research, which I could not confirm from a primary source. — [Artificial Analysis](https://artificialanalysis.ai/articles/qwen3-5-small-models); [Gigazine](https://gigazine.net/gsc_news/en/20260303-qwen-3-5-small); [DeepLearning.AI The Batch](https://www.deeplearning.ai/the-batch/alibabas-latest-flagship-models-are-open-weights-moe-performers-in-sizes-from-less-than-1b-parameters)
- mlx-swift-lm registers the `qwen3_5` architecture, but its default registry only pre-configures Qwen3.5-27B and 35B-A3B, not the 2B or 4B. — [mlx-swift-lm VLMModelFactory.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXVLM/VLMModelFactory.swift)
- **Qwen3-VL-2B-Instruct** is licensed apache-2.0, has 2B parameters, and has about 99 quantized community builds for llama.cpp, Ollama, LM Studio and others. — [Hugging Face: Qwen/Qwen3-VL-2B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct)
- A community guide (not a benchmark) maps the 2B to 8 GB Apple Silicon Macs and the 4B to 16 GB Macs under MLX. — [local-llm.net Qwen3-VL](https://www.local-llm.net/models/qwen3-vl/)
- **SmolVLM2** comes in 256M, 500M and 2.2B. Hugging Face's HuggingSnap iPhone app runs the 500M model fully offline via a modified mlx-swift-examples and needs iOS 18. The 2.2B MLX build is 4.49 GB on disk. No iPhone RAM measurements were found. — [Digital Trends (HuggingSnap)](https://qa2.www.digitaltrends.com/mobile/huggingsnap-app-iphone-rival-visual-intelligence-works-offline); [Codersera SmolVLM2-2.2B guide](https://codersera.com/blog/run-smolvlm2-22b-on-macos-installation-guide/amp/)
- **FastVLM** comes in 0.5B, 1.5B and 7B (the 7B uses Qwen2-7B), from CVPR 2025. The 0.5B claims an 85x faster TTFT than LLaVA-OneVision-0.5B with a vision encoder 3.4x smaller. — [apple/ml-fastvlm](https://github.com/apple/ml-fastvlm); [arXiv 2412.13303](https://arxiv.org/pdf/2412.13303)
- A secondary blog claims FastVLM TTFT "as low as 31.7 ms" on iPhone 16 Pro. This is unverified against Apple's materials and is likely vision-encoder-only. — [buildfastwithai](https://buildfastwithai.com/blogs/google-nano-banana-vs-apple-fastvlm)
- **MiniCPM-V 4.5** is about 8B (the page variously says 8B, 8.7B and 9B), built on Qwen3-8B with SigLIP2-400M, under Apache-2.0 with an optional registration questionnaire. It ships int4, GGUF and AWQ builds, and the page cites an iOS app for iPhone/iPad with the demo shown on an iPad M4. — [Hugging Face: openbmb/MiniCPM-V-4_5](https://huggingface.co/openbmb/MiniCPM-V-4_5)
- **Gemma 3** has a 400M SigLIP vision encoder at 896×896, and vision is supported only on the 4B, 12B and 27B sizes. — [Hugging Face Gemma 3 blog](https://huggingface.co/blog/gemma3)
- **Gemma 3n** E2B/E4B are multimodal (text, vision, audio). LiteRT-LM benchmarks list them only on a MacBook Pro M3 (E2B: 233 prefill / 28 decode tk/s) and a Samsung S24 Ultra (111 / 16), with no iPhone rows. — [LiteRT-LM overview](https://developers.google.com/edge/litert-lm/overview)
- The bigger models used as quality references in food papers are all far above an iPhone's memory budget: Qwen2.5-VL-72B, Gemma-3-27B, and Llama-3.2-Vision-90B. — [arXiv 2507.07048](https://arxiv.org/html/2507.07048v1)

### Inferences
- **Best on-device shortlist for Trio:** Gemma 4 E2B (about 2.6 GB file, about 3.5 GB peak in practice), Qwen3.5-2B, and Qwen3-VL-2B. Gemma 4 E4B, Qwen3.5-4B and Qwen3-VL-4B fit on paper (about 2.5–3.7 GB at 4-bit) but leave little headroom on an 8 GB iPhone 15 Pro, given the reported ~6 GB process cap and the need to keep the insulin loop alive. MiniCPM-V 4.5, Qwen3-VL-8B, Qwen3.5-9B and Llama 3.2 11B Vision should be treated as not viable on iPhone for this app.
- Qwen3.5-4B's reported MMMU-Pro (65.4%) is well above Qwen3-VL-8B (56.6%). If those scores hold, Qwen3.5-2B/4B may be the strongest small open VLMs per byte as of October 2026. This rests on aggregator-reported numbers and is unverified.
- Llama 3.2 Vision 11B is too big: over 6 GB at 4-bit plus a vision encoder. It also scored worst on macronutrients in the 90B form tested by arXiv 2507.07048.

### Gaps
- There are no published iPhone peak RAM or latency figures for Qwen3.5-2B/4B, Qwen3-VL-2B/4B, SmolVLM2-2.2B, Moondream, or Phi-4-multimodal.
- I did not research Moondream (any version) or Phi-4-multimodal in this pass, so their licensing and iPhone viability are unverified.
- Gemma 4 MMMU-Pro figures and Qwen3.5 benchmark numbers come from secondary aggregators; I did not read the primary model cards.

## 3. iOS memory limits (jetsam, increased-memory-limit entitlement) and the risk to Trio's insulin loop

### Takeaway
On 8 GB and 12 GB iPhones, developers report a per-process ceiling of about **6 GB (6144 MB) even with `com.apple.developer.kernel.increased-memory-limit`**. A 2–4B VLM therefore consumes roughly half to two-thirds of the app's entire budget. Crossing the limit terminates the **whole process**, and Trio's dosing loop, pump/CGM managers and BLE sessions all live in that one process. App extensions have much lower limits, so moving inference into an extension is not an escape hatch. This is the single most critical engineering risk of on-device VLMs in Trio.

### Cited Findings
- Apple describes the entitlement as letting an app's core features run with a higher memory limit on supported devices. The increase is available only on some device models. Apps should call `os_proc_available_memory()` and still behave correctly if the extra memory is not available. — [Apple: increased-memory-limit entitlement](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit.md)
- June 2026 developer measurements used `os_proc_available_memory()` and `phys_footprint`. The ceiling was about 6144 MB on iPhone 16 Pro Max (8 GB) and on iPhone 17 Pro Max (12 GB) with increased-memory-limit. Adding extended-virtual-addressing made no change. Adding increased-debugging-memory-limit raised it to about 6656 MB, but that is a debug entitlement. A 12 GB iPad exposed more. There was no Apple reply, and the feedback is filed as FB23183521. — [Apple Developer Forums 834805](https://developer.apple.com/forums/thread/834805)
- Another developer reported that the entitlement raised an iPad's limit to about 15 GB in a development build, but the App Store build crashed at about 6 GB. — [Apple Developer Forums 770868](https://developer.apple.com/forums/thread/770868)
- On iOS, all entitlements must be authorized by a provisioning profile. Increased Memory Limit is enabled under the App ID capabilities in Certificates, Identifiers & Profiles. — [Apple Developer Forums 770868 (DTS reply)](https://developer.apple.com/forums/thread/770868)
- A benchmark author states that "Jetsam kills apps using roughly 50–67% of total RAM" depending on device state, which is about 6 GB on a 12 GB device. This is a secondary claim. — [Ricky Takkar blog](https://rickytakkar.com/blog_russet_mlx_benchmark.html)
- Apple's jetsam documentation lists the reason `per-process-limit` as "The process crossed the resident memory limit imposed by the system on all apps", which makes it eligible for termination. It notes that "extensions have a much lower per-process memory limit than foreground apps". The reason `vm-pageshortage` means the system needed to free background process memory for the foreground app. "If the system jettisons your app due to memory pressure while the app is visible, it will look like your app crashed." — [Apple: Identifying high-memory use with jetsam event reports](https://developer.apple.com/tutorials/data/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports.md)
- The mlx-swift-lm developer avoided jetsam only by shrinking the MLX GPU buffer cache from 512 MB to 64 MB. With about 4.4 GB resident, only about 1.7 GB was left for prefill. — [Apple Developer Forums 834805](https://developer.apple.com/forums/thread/834805)
- The hermit study saw no jetsam with Gemma 4 E2B on iPhone 16 Pro, but explicitly did not test real OS memory pressure. — [hermit issue #2](https://github.com/JaviChulvi/hermit/issues/2)

### Inferences
- **Same-process risk.** Trio runs its loop, pump and CGM drivers and BLE in the main app process. A `per-process-limit` jetsam during inference kills the loop mid-cycle, possibly during pump communication. It recovers only when iOS relaunches the app, for example via a BLE background relaunch, or when the user reopens it. The design must make OOM structurally impossible, not merely unlikely.
- **Background-residency risk.** If a multi-GB model stays loaded after the user leaves the treatment screen, Trio becomes the "largestProcess" candidate for `vm-pageshortage` kills while backgrounded. That is exactly when it must keep looping. Mitigation: load the model only on demand, unload it immediately after inference and on `didEnterBackground` and memory warnings, and never let inference run in the background.
- **Practical budget.** Take about 6 GB for the process, minus Trio's own footprint (unmeasured here; check with Instruments), minus a safety margin. That suggests a 2B-class 4-bit model (about 2.5–3.5 GB peak) is the realistic ceiling on 8 GB phones, with an explicit `os_proc_available_memory()` gate before loading. That gate should refuse to load and fall back to manual entry when headroom is insufficient.
- Using an app extension to isolate the model is not viable, because Apple documents much lower extension limits. A separate process with its own budget is not available to third-party iOS apps outside extensions.
- Trio is built and signed by users with their own developer accounts. Each builder would need to enable the Increased Memory Limit capability on their own App ID and profile, which adds a setup step to the build process.

### Gaps
- Apple does not publish per-device limits. The ~6 GB figure comes from one developer's measurements on 16 Pro Max and 17 Pro Max. I found no measurement for iPhone 15 Pro (8 GB) with the entitlement.
- I found no evidence on whether jetsam treats a foreground app with active BLE/HealthKit background modes differently, nor any study of how a VLM-loaded app behaves under real multi-app memory pressure.
- I found no documentation on whether MLX's Metal allocations count fully against `phys_footprint` differently from mmap'd llama.cpp weights.

## 4. App size and model distribution: bundling vs. on-demand download

### Takeaway
Bundling a 1.5–4 GB model in an app that users build from source and install via Xcode or TestFlight is impractical: it bloats the repo or build, and Git LFS is a burden. The realistic path is an opt-in, first-use download from Hugging Face, which is how mlx-swift-lm and the llama.cpp examples work. Apple-hosted Background Assets (iOS 26) are designed for App Store Connect-distributed apps and have reported reliability issues.

### Cited Findings
- Background Assets on iOS 26 adds Managed Background Assets. The system handles downloads, updates and compression, and apps can use Apple-hosted storage of up to 200 GB of compressed assets for TestFlight or App Store apps. Machine-learning models are an explicitly supported content type and can be updated without a new app build. — [App Store Connect Help: Apple-hosted asset packs](https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs); [Apple: Downloading Apple-hosted asset packs](https://developer.apple.com/documentation/backgroundassets/downloading-apple-hosted-asset-packs.md)
- Implementing it requires a downloader extension target, App Groups on both the app and the extension, and Info.plist keys. Packs can download before launch, prefetch, or download on demand. The APIs require iOS 26.0. — [Apple: Background Assets](https://developer.apple.com/documentation/backgroundassets.md); [Apple: BAAssetPackManager](https://developer.apple.com/documentation/backgroundassets/baassetpackmanager.md)
- One developer reported that on iOS 26.4–26.6, about 955 MB across 14 packs completed on only 68% of 7,384 devices. About 6% failed hard, and about 25% never finished, partly because a background continued-processing task expired. This is anecdotal and not an Apple statement. — [Apple Developer Forums 845723](https://developer.apple.com/forums/thread/845723)
- On-disk sizes:
  - Gemma 4 E2B LiteRT: 2.58 GB. Gemma 4 E4B: 3.65 GB. — [LiteRT-LM overview](https://developers.google.com/edge/litert-lm/overview)
  - SmolVLM2-2.2B MLX: 4.49 GB. — [Codersera](https://codersera.com/blog/run-smolvlm2-22b-on-macos-installation-guide/amp/)
  - Qwen3.5-9B: about 6.6 GB via Ollama. — [Gigazine via search](https://gigazine.net/gsc_news/en/20260303-qwen-3-5-small)
- MLC's iOS app downloads pre-converted weights from Hugging Face at runtime, and mlx-swift-lm registry entries are Hugging Face repo IDs. — [MLC LLM iOS](https://llm.mlc.ai/docs/deploy/ios.html); [mlx-swift-lm VLMModelFactory.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXVLM/VLMModelFactory.swift)
- llama.cpp needs the model file uncompressed on disk because it mmaps it. — [Liquid AI docs](https://docs.liquid.ai/deployment/on-device/llama-cpp/mobile)

### Inferences
- Apple-hosted asset packs are tied to an App Store Connect app record. Every Trio builder has their own bundle ID and App Store Connect record, so each would have to upload the asset packs themselves, which is impractical. A Hugging Face (or GitHub release) download pinned by revision or commit hash and verified by SHA-256 is the pragmatic option.
- Users should see the storage cost (about 2–4 GB) and an explicit opt-in. The download should be resumable, run on Wi-Fi only, and never run during critical loop work.
- Pin model revisions. A silently updated Hugging Face repo could change macro outputs for a dosing-adjacent feature.

### Gaps
- I found no data on Hugging Face download reliability or speed from iOS apps.
- I did not determine whether Background Assets' self-hosted (non-Apple) mode works for apps sideloaded via Xcode or personal TestFlight. That was not checked.

## 5. Specialized food models: classifiers, nutrient regressors, depth/LiDAR portion estimation

### Takeaway
Small task-specific models exist and can be very small. One example is CalorieK, a 94M-parameter SigLIP2 regressor under MIT that predicts kcal, mass, protein, carbs and fat. Another is Food-R1, a fine-tuned Qwen3-VL-8B with released weights. Their headline numbers come from in-distribution test splits such as Nutrition5k and CalorieBench, and may not generalize to home meals. Depth-based portion estimation has research support (about 14% weight error on iPhone X depth), but I found no open-source LiDAR food-volume code.

### Cited Findings
- **CalorieK** (Dralkh/CalorieK, 2026, MIT): a google/siglip2-base-patch16-224 vision tower with a regression head, about 93.7M parameters. Its five outputs are kcal, mass, protein, carbs and fat. On the Nutrition5k 606-dish test it reports kcal MAE 56.3 (median 30.0), mass 55.3 g, protein 6.2 g, **carbs 6.3 g**, and fat 5.0 g. On the same page: Food-R1 (8-bit) 77.0 kcal MAE, Boba 0.8B (Q4_K_M) 79.5, Qwen3.5-9B (8-bit) 82.6 on a 303-dish subset, and CalorieCLIP 126.4. It was trained on one RTX 4080, and the page makes no on-device claims. These are self-reported results on a model card and have not been peer reviewed. — [Hugging Face: Dralkh/CalorieK](https://huggingface.co/Dralkh/CalorieK)
- **Food-R1** (arXiv 2606.04986, June 2026) is a fine-tune of Qwen3-VL-8B (CoT cold start plus GRPO RL). On CalorieBench-80K it reaches calorie MAE 42.56 and R² 0.81, against GPT-4o-mini 88.40, Qwen2.5-VL-72B 120.95, Qwen3-VL-8B 195.18, LLaVA-7B 200.79, InternVL3-8B 218.70, and Gemini-2.5-flash 301.87 (R² −5.77). It reports Food-101 top-1 of 95.21%. Code and weights are on GitHub (hustvl/Food-R1) and Hugging Face, but the license is not stated in the paper. — [arXiv 2606.04986 (HTML)](https://arxiv.org/html/2606.04986v1)
- **Depth-based volume:** a 2020 JMIR mHealth study used an iPhone X structured-light depth app (not LiDAR). It reported a mean relative absolute error of 14.0% for meal weight (35.1 g) and about 13% for energy, at about 23 s per meal, with cooked meals worse than breakfasts and snacks. — [JMIR mHealth and uHealth 2020 (DOAJ record)](https://doaj.org/article/0a887b9d85454e81a7c2130efcb3b497); [Univ. Bern repository](https://boris.unibe.ch/147780)
- Conventional dietary assessment portion error "averages above 20%", which is the main error source. — [arXiv 1701.03330](https://arxiv.org/pdf/1701.03330)
- A July 2026 arXiv paper, "Geometry-Enhanced Portion Estimation for Multimodal LLMs", targets the portion-size weakness of MLLMs. I found it in search results but did not read it. — [arXiv 2607.16514](https://arxiv.org/pdf/2607.16514)
- Commercial apps advertise LiDAR portioning (for example FoodTrack, "portion estimated via LiDAR sensor when available") without accuracy data. Hackathon projects such as CalorAI follow a LiDAR volume × density approach, with no repository or accuracy data. — [FoodTrack App Store](https://apps.apple.com/app/id6762207499); [Devpost CalorAI](https://devpost.com/software/calorai)

### Inferences
- A hybrid design is plausible. A small VLM (or Apple's on-device model) would identify and describe the foods. A tiny regressor (CalorieK-class, about 94M parameters, easily Core ML-convertible as a SigLIP2 tower) or a nutrition-database lookup would supply the numbers. Optionally, LiDAR or depth would scale portions. This uses far less memory than a 2–4B VLM, which would lower the jetsam risk.
- Nutrition5k is cafeteria dishes shot overhead under fixed conditions. CalorieK's 6.3 g carb MAE is in-distribution, and real-world home-meal error will almost certainly be higher. It should not be compared directly with the ACETADA numbers in Q6.
- Food-R1 shows that domain fine-tuning moves an 8B open model from far worse than GPT-4o-mini to about 2x better, in-distribution. The same recipe applied to a 2–4B base, such as Qwen3.5-2B/4B or Gemma 4 E2B, is the most promising route to on-device quality. I found no such release.

### Gaps
- No open-source, on-device-ready food classifier or regressor validated on carbohydrate accuracy for real-world (non-Nutrition5k) meals.
- No study of iPhone LiDAR (as opposed to the iPhone X TrueDepth sensor) food volume accuracy.
- Food-R1 weight license unknown.

## 6. Quality: small VLMs vs. frontier models on food recognition and nutrient estimation

### Takeaway
Even frontier models have large errors on real meals. In a 2025 controlled-feeding study (ACETADA), Claude 3.7 Sonnet, GPT-4o and GPT-4.1 had carb MAE of about 23–25 g (35–42% MAPE), and Gemini 2.5 Pro about 28 g. Untuned small open VLMs are substantially worse. In 2026 benchmarks, Qwen3-VL-8B had about 2x GPT-4o-mini's calorie error on CalorieBench and about 2x GPT-5.1's macro-gram MAPE on MM-Food-derived data. I found **no published macronutrient benchmark of any ≤4B on-device VLM** (Gemma 4 E2B/E4B, Qwen3.5-2B/4B, SmolVLM2, FastVLM).

### Cited Findings
- **ACETADA** (arXiv 2507.07048, July 2025) has 806 meal images with dietitian-weighed ground truth from a controlled-feeding study of 152 adults. Baseline (no metadata) carbs MAE / MAPE:
  - Claude 3.7 Sonnet: 25.01 g / 37.2%
  - GPT-4.1: 22.90 g / 39.3%
  - GPT-4o: 23.37 g / 42.1%
  - Gemini 2.5 Pro: 28.47 g / 50.2%
  - Gemma-3-27B: 24.51 g / 51.2%
  - Qwen2.5-VL-72B: 38.35 g / 50.0%
  - Janus-Pro-7B: 53.31 g / 67.2%
  - Llama-3.2-Vision-90B: 45.61 g / 66.8%

  Energy MAE ranged from 166 kcal (GPT-4o) to 496 kcal (Llama 90B). Adding GPS and timestamp metadata cut calorie MAE for every model, by about 76 kcal on average. Open models gained most, and the paper concludes that lightweight context can let open models close the gap. — [arXiv 2507.07048](https://arxiv.org/html/2507.07048v1)
- **CalorieBench-80K** (Food-R1 paper, June 2026), calorie MAE: GPT-4o-mini 88.4, Qwen3-VL-8B 195.2, InternVL3-8B 218.7, LLaVA-7B 200.8, Gemini-2.5-flash 301.9, fine-tuned Food-R1 (8B) 42.6. — [arXiv 2606.04986](https://arxiv.org/html/2606.04986v1)
- **OmniFood-Bench** (arXiv 2607.08423, July 2026) has 1,208 samples from MM-Food-100K. It reports MAPE of total macronutrient grams by category (Homemade / Restaurant / Packaged / Raw):
  - gpt-5.1: 49 / 41 / 80 / 123
  - claude-sonnet-4: 61 / 50 / 89 / 347
  - gemini-3-flash: 114 / 71 / 168 / 209
  - qwen3-vl-8B: 102 / 64 / 315 / 262
  - InternVL3.5-8B: 64 / 49 / 217 / 258
  - Llama-3.2-11B-Vision: 90 / 63 / 406 / 143

  Closed models were evaluated on a 496-sample subset, so the comparison is not perfectly matched. All runs were zero-shot. On diabetes-advice accuracy, qwen3-vl-8B scored 28.06 against gpt-5.1's 41.13. — [arXiv 2607.08423](https://arxiv.org/html/2607.08423v2)
- **Nutrition5k, ten-model benchmark** (bioRxiv, posted 2026-07-29), 3,229 images: Gemini 3.0 Flash was best on calories (CCC 0.767, MAE 80.7 kcal), followed by Gemini 3.1 Flash Lite (CCC 0.754) and Gemini 2.0 Flash (CCC 0.742). Ingredient Jaccard was highest for 3.1 Flash Lite (0.655). Human re-annotation found Nutrition5k labels systematically omit ingredients, and Gemini 2.0 Flash's Jaccard rose from 0.62 to about 0.82 after correction. Qwen2-VL-7B was included, but its results and the macronutrient numbers were not visible in the abstract page. — [bioRxiv 10.64898/2026.07.26.740845](https://www.biorxiv.org/content/10.64898/2026.07.26.740845v1)
- A Gothenburg study used 52 standardized photos. Energy MAPE was about 36% for ChatGPT-4o and Claude 3.5 Sonnet and about 64% for Gemini 1.5 Pro. Protein MAPE exceeded 60%. This comes from search snippets of the published paper; I did not read the full text. — [ScienceDirect (Current Developments in Nutrition)](https://www.sciencedirect.com/science/article/pii/S2475299125030185)
- Domain-fine-tuned small models beat general large ones on Nutrition5k-style tests: CalorieK (94M) 56.3 kcal MAE against Qwen3.5-9B at 82.6 (subset). These are self-reported and in-distribution. — [Hugging Face: Dralkh/CalorieK](https://huggingface.co/Dralkh/CalorieK)

### Inferences
- The frontier "ceiling" is itself about ±20–25 g carb MAE per meal on realistic meals (ACETADA). At a 1:10 g/U carb ratio, that is about 2–2.5 U of potential bolus error. Any feature must present estimates as editable suggestions, which matches the planned confirm-before-save UX.
- Untuned 2–4B models will likely be worse than the 7–8B open models measured. Those 7–8B models are already about 1.5–2x worse than GPT-4o-class models on calories and much worse on packaged and raw foods. A rough expectation for zero-shot 2–4B on-device VLMs is food *description* quality acceptable for common dishes, but macro numbers materially worse than cloud. This is an extrapolation, not a measurement.
- The cheapest quality levers on-device are domain fine-tuning (Food-R1 shows large gains), adding context (time of day, the user's typical meals; ACETADA shows big gains for open models), and decoupling numbers from the VLM (regressor or database).

### Gaps
- No benchmark on any dataset for Gemma 4 E2B/E4B, Qwen3.5-0.8B/2B/4B, Qwen3-VL-2B/4B, SmolVLM2, FastVLM, MiniCPM-V 4.5, or Moondream on carbs, protein or fat.
- The bioRxiv benchmark's macronutrient and Qwen2-VL-7B results were not accessible from the abstract page.
- I did not locate NutriBench (text-only meal descriptions) or other "FoodVLM" benchmark results in this pass.
- Few benchmarks report *carbohydrate* error specifically. Most headline calories, which matter less for insulin dosing.

## 7. Cloud baseline: BYO-key Claude / OpenAI / Gemini cost, latency, privacy, offline failure

### Takeaway
Cloud vision calls cost on the order of **$0.0001–$0.01 per meal photo**, which is negligible for personal use. They are the accuracy ceiling in every food benchmark found. Default API retention is about 30 days at Anthropic and OpenAI, while Gemini's paid tier excludes data from product improvement and its free tier does not. The failure mode is total when offline. I found no published API latency figures for this task.

### Cited Findings
- **Anthropic.** Image cost is ⌈w/28⌉×⌈h/28⌉ visual tokens, so a 1000×1000 image is 1,296 tokens. The docs' example is about $1.30 per 1,000 images on Claude Haiku 4.5 ($1/M input) and about $6.48 per 1,000 on Claude Opus 5 ($5/M, high-resolution tier). Claude 4.7+ models accept up to 2576 px long edge and 4,784 visual tokens; others 1568 px and 1,568 tokens. Images are "not stored beyond the duration of the API request", and Anthropic "does not use uploaded images to train models". — [Claude docs: Vision](https://platform.claude.com/docs/en/build-with-claude/vision)
- Anthropic's commercial default deletes API inputs and outputs "within 30 days of receipt or generation". Content flagged for usage-policy violations is kept up to 2 years. Zero data retention is a per-organization arrangement that needs approval. Retained data is never used for training without express permission. — [Anthropic Privacy Center: commercial retention](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data); [Claude docs: API and data retention](https://platform.claude.com/docs/en/manage-claude/api-and-data-retention)
- **OpenAI** (pricing page, undated, references July–November 2026 changes), per 1M input/output tokens:
  - gpt-5-nano: $0.05 / $0.40
  - gpt-4o-mini: $0.15 / $0.60
  - gpt-5.4-nano: $0.20 / $1.25
  - gpt-5.6-luna: $0.20 / $1.20
  - gpt-5-mini: $0.25 / $2.00
  - gpt-5.4-mini: $0.75 / $4.50
  - gpt-5.4: $2.50 / $15
  - gpt-5.5: $5 / $30

  The page gives no image-token rate for these models. — [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)
- OpenAI keeps API abuse-monitoring logs "for up to 30 days". ZDR or Modified Abuse Monitoring requires prior approval. A community post says `/v1/responses` stores objects for 30 days unless `store=false`. — [OpenAI: Your data](https://developers.openai.com/api/docs/guides/your-data); [OpenAI community](https://community.openai.com/t/for-how-long-does-openai-vision-api-stores-processed-images/1378689)
- **Google Gemini** (pricing page updated 2026-10-09), paid per 1M input/output tokens:
  - Gemini 3.1 Flash-Lite: $0.25 / $1.50
  - Gemini 3.5 Flash-Lite: $0.30 / $2.50
  - Gemini 3 Flash Preview: $0.50 / $3.00
  - Gemini 3.8 Flash: $0.75 / $3.75 through 2026-12-31, then $1.50 / $7.50
  - Gemini 3.1 Pro Preview: $2 / $12

  Free tier: "Content used to improve our products". Paid tier: content "not used to improve our products". — [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)
- Gemini paid-services terms say prompts (including images) are not used to improve products. Data may be stored transiently or cached in any country where Google operates. Only paid services may be offered to users in the EEA, Switzerland or the UK. — [Gemini API Additional Terms](https://ai.google.dev/gemini-api/terms)
- Measured cost per image on Nutrition5k (July 2026): Gemini 2.0 Flash $0.10 per 1K images, Gemini 3.1 Flash Lite $0.59 per 1K. — [bioRxiv 2026.07.26.740845](https://www.biorxiv.org/content/10.64898/2026.07.26.740845v1)
- Cloud accuracy references are in Q6. GPT-4o, GPT-4.1 and Claude 3.7 had carbs MAE of about 23–25 g on ACETADA. GPT-5.1 had the lowest macro-gram MAPE on OmniFood-Bench. Gemini 3.0 Flash had the best calorie CCC on Nutrition5k. — [arXiv 2507.07048](https://arxiv.org/html/2507.07048v1); [arXiv 2607.08423](https://arxiv.org/html/2607.08423v2); [bioRxiv](https://www.biorxiv.org/content/10.64898/2026.07.26.740845v1)

### Inferences
- A 1–1.5K-token image plus a short prompt and a JSON answer costs well under one cent on any mid-tier model, and about $0.0001–0.0005 on nano or flash-lite tiers. Cost is not a deciding factor for a single user.
- **Privacy.** With BYO key the user is the API customer. Meal photos are health-adjacent data held for about 30 days at Anthropic and OpenAI by default. Gemini free-tier keys allow human review and product use, so Trio should warn users to use a billing-enabled Gemini key, or recommend against free-tier keys.
- **Offline / outage behavior.** The cloud path must fail closed to manual entry, with a short timeout. It must never block or delay the loop, and network calls must be fully decoupled from loop scheduling.
- Gemini models have been inconsistent across benchmarks: worst on CalorieBench (2.5-flash) and ACETADA (2.5 Pro), but best on Nutrition5k (3.0 Flash). Model choice within a provider matters as much as the provider.

### Gaps
- I found no measured end-to-end latency (upload plus inference) for vision calls from a phone to any of the three providers.
- I did not confirm OpenAI's image-token accounting for the GPT-5.x models.
- I did not check Anthropic's or Google's HIPAA or BAA posture for individual BYO-key users. It is likely not applicable to personal keys, but unverified.

## 8. Licensing constraints for embedding or using models in AGPL-3.0 Trio

### Takeaway
The mainstream small candidates are permissively licensed and compatible with an AGPL-3.0 app: Gemma 4 (Apache 2.0), Qwen3-VL and Qwen3.5 (Apache 2.0), MiniCPM-V 4.5 (Apache 2.0 per its model card), mlx-swift-lm (MIT), and CalorieK (MIT). **Apple FastVLM's model weights are research-only and exclude product use**, which makes them unsuitable for Trio even though Trio is non-commercial and built from source. Earlier Gemma generations (3, 3n) used Google's custom Gemma terms rather than Apache 2.0.

### Cited Findings
- FastVLM `LICENSE_MODEL` grants use "exclusively for Research Purposes", defined as non-commercial scientific research and academic development. It excludes commercial products and services. Redistribution is allowed with the agreement and attribution, and derivatives stay research-only. Apple may terminate the license. The code has a separate `LICENSE`. — [apple/ml-fastvlm LICENSE_MODEL](https://raw.githubusercontent.com/apple/ml-fastvlm/main/LICENSE_MODEL); [apple/ml-fastvlm](https://github.com/apple/ml-fastvlm)
- Gemma 4 is Apache 2.0, "abandoning its restrictive custom license", the first Gemma generation under Apache 2.0. — [The Decoder](https://the-decoder.com/googles-gemma-4-is-now-available-with-apache-2-0-licensing-for-the-first-time/)
- Qwen3-VL-2B-Instruct is licensed apache-2.0. — [Hugging Face](https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct)
- Qwen3.5 small models (0.8B–9B) are Apache 2.0. — [Artificial Analysis](https://artificialanalysis.ai/articles/qwen3-5-small-models)
- MiniCPM-V 4.5 is "open-sourced under the Apache-2.0 license", with an optional registration questionnaire. — [Hugging Face: openbmb/MiniCPM-V-4_5](https://huggingface.co/openbmb/MiniCPM-V-4_5)
- mlx-swift-lm is MIT. — [GitHub](https://github.com/ml-explore/mlx-swift-lm)
- CalorieK is MIT. — [Hugging Face](https://huggingface.co/Dralkh/CalorieK)
- Apache 2.0 software "can therefore be included in GPLv3 projects", and the incompatibility runs in one direction only (GPLv3 into Apache). — [Apache Software Foundation: GPL compatibility](https://www.apache.org/licenses/GPL-compatibility.html)
- The Food-R1 paper does not state a license for its weights. — [arXiv 2606.04986](https://arxiv.org/html/2606.04986v1)

### Inferences
- If Trio downloads weights at runtime rather than committing them, the AGPL question mostly concerns the inference code (mlx-swift-lm MIT and llama.cpp MIT, both compatible). Model weights would be separately licensed data, and the weight license's use restrictions still bind users. That is a reading of how the licenses interact, not legal advice.
- FastVLM is the only candidate whose license plainly forbids product use. Trio's AGPL release plus self-build distribution is arguably "product development", not "Research Purposes", so FastVLM should be excluded.
- Gemma 3 and 3n weights carry Google's Gemma Terms of Use and Prohibited Use Policy. Gemma 4 removes that concern by moving to Apache 2.0, which favors Gemma 4 over Gemma 3/3n.
- Apache 2.0 requires NOTICE and attribution, so the downloaded-model UI or about screen should carry attribution.

### Gaps
- I did not read the text of the Gemma Terms of Use or Prohibited Use Policy for Gemma 3/3n this pass, including any medical-use clause.
- Not verified this pass: the Llama 3.2 Community License (including its EU multimodal restriction), SmolVLM2's license (believed Apache 2.0), Moondream's license, and Phi-4-multimodal's license (believed MIT).
- I did not verify the license on Qwen3.5-2B/4B model cards directly. I also could not confirm a third-party claim that Alibaba scopes those models to prototyping and research.
- Food-R1 weights license unknown.
