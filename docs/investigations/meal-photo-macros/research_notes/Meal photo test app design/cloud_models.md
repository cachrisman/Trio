# Cloud VLM picks for the meal-photo macro test app

Research date: 2026-10-13. Scope: one meal photo plus an optional one-line text hint goes in, and a JSON result comes back (description, carbs/protein/fat in grams, optional per-item breakdown and confidence). It is a personal comparison at low volume (tens to hundreds of images). Sources: official pricing/model/vision/structured-output docs fetched today (Anthropic via the `claude-api` skill, cached 2026-10-06, then checked against platform.claude.com), plus the live OpenRouter `/api/v1/models` JSON pulled today. Anything I estimated or could not verify is labelled **[assumption]** or **[unverified]**.

## Cost model used everywhere

- **Image:** 1024x1024 JPEG, resized on the phone before upload. That is the worst case at that size. A 4:3 1024x768 shot costs about 25% fewer image tokens on the patch-based APIs.
- **Text in:** about 400 tokens for the system prompt, schema instructions and hint **[assumption]**.
- **Visible output:** about 300 tokens of JSON.
- **Reasoning/thinking tokens:** every provider bills these as output. I assume about 500 tokens at "low" effort and about 1,000 at "medium" **[assumption; measure with `usage` fields]**. Where thinking can be turned off, the "floor" figure below excludes it.
- **Image tokens per provider for 1024x1024:**
  - **Anthropic:** `ceil(w/28) x ceil(h/28)` gives 37x37 = **1,369 tokens**. This holds on all current models. Opus/Sonnet/Haiku 4.7+ are "high-res tier" (max 2576 px long edge / 4,784 tokens), but a 1024 px image is not resized on either tier. Doc table: 1000x1000 = 1,296 tokens, 1092x1092 = 1,521 tokens.
  - **OpenAI (GPT-6 / GPT-5.6, patch-based):** 32 px patches x 1.2 multiplier, so 32x32 = 1,024 patches gives **1,229 tokens**. The docs state 1,229 explicitly for `gpt-6-astra` at `detail: high`. With `detail: "low"` (fit to 512x512) it drops to about 308 tokens. The vision page lists `gpt-6-astra` and `gpt-5.6-*` but not `gpt-6.1-sol` / `gpt-6-luna`. I assume the same rule for those two **[assumption]**.
  - **Gemini 3.x:** a fixed count per image set by `media_resolution`: low 280, medium 560, high 1,120, ultra_high 2,240. The default is **1,120**. Using `medium` would halve image cost, but it may lose detail.
  - **Qwen / Grok / Mistral via OpenRouter:** not documented on OpenRouter. My guess is ~1,000–1,300 tokens **[assumption]**.

## Anthropic (direct API)

Models, IDs and prices are from the skill table and the models overview page (Claude API, standard tier):

| Model | API ID | $/MTok in / out | Thinking control | Comparative latency (Anthropic label) |
|---|---|---|---|---|
| Claude Fable 5.1 | `claude-fable-5-1` | $10 / $50 | always on; `output_config.effort` low…max (default high) | Slower |
| **Claude Opus 5.5** | `claude-opus-5-5` | $4 / $20 | always on (`disabled` = 400); effort default **medium**, use `low` | Moderate |
| **Claude Sonnet 5.5** | `claude-sonnet-5-5` | $2 / $10 | adaptive; turn off with `thinking: {type: "between_tools"}` (effort ≤ high); `disabled` = 400 | Fast |
| Claude Haiku 5.5 | `claude-haiku-5-5` | $0.10 / $0.50 (prompts ≤100K; $0.50/$2.50 above) | adaptive, default effort medium; `disabled` allowed at effort ≤ high | Fastest |

- **Best quality: `claude-opus-5-5`.** About **$0.013/photo** without thinking, which is not possible on this model, and **~$0.02–0.03** at effort `low` **[assumption on thinking tokens]**. Anthropic's own guidance is "start with Opus 5.5". Fable 5.1 is 2.5x the price, ~$0.03–0.07/photo, and is aimed at long-horizon reasoning, so it is worth one run only as a ceiling probe. A Claude-only food study (Nutrients 2026, 18(12):2017; snippet only, full text 403) found Sonnet 4.6 and Opus 4.6 close (MedAPE within 1–3 points) and both well ahead of Haiku 4.5. So a gap between Opus and Sonnet on this task is plausibly small.
- **Cost-effective: `claude-sonnet-5-5`.** About **$0.0065/photo** with thinking off (`between_tools`) and ~$0.012 with thinking on. Haiku 5.5 costs ~$0.0003–0.0006/photo and is worth including as a cheap baseline. The previous Haiku was clearly worse on food in the study above, and I found no food evidence for Haiku 5.5 (released 2026-10-07).
- **Image input:** yes on all models. JPEG/PNG/GIF/WebP, base64/URL/Files API, 10 MB per image on the direct API. Put the image before the text.
- **Structured output: "Structured outputs", GA, no beta header.** Send `output_config: {format: {type: "json_schema", schema: {...}}}` on `messages.create`, or use the SDK `messages.parse()`. Alternatively use a tool with `strict: true`. The supported list includes opus-5-5, sonnet-5-5, haiku-5-5 and fable-5-1. Schema limits:
  - No `minimum`/`maximum`/`minLength`, so range checks belong in the app.
  - `additionalProperties` must be `false`.
  - At most 24 optional params.
  - A `stop_reason: "refusal"` or `max_tokens` cut can break the schema.
  - Assistant prefill returns a 400 on these models.
  - Forced `tool_choice` `any`/`tool` returns a 400 on Opus 5.5 and Sonnet 5.5. Use `output_config.format` rather than forced tools.
- **Latency notes:** Opus 5.5 always thinks, so use effort `low` to keep it quick. Sonnet 5.5 with `between_tools` is the fast no-think path.

## OpenAI (direct API)

Prices are from developers.openai.com/api/docs/pricing (Standard, ≤272K context). Positioning is from the models page:

| Model | ID | $/MTok in / cached / out | Reasoning effort |
|---|---|---|---|
| **GPT-6 Astra** (flagship, "most capable") | `gpt-6-astra` | $10 / $1.00 / $50 | low, medium, high, xhigh, max (no `none`) |
| **GPT-6.1 Sol** ("near-Astra performance… at a lower cost") | `gpt-6.1-sol` | $2 / $0.10 / $10 | low…max (no `none`) |
| GPT-6 Luna ("most efficient… high-volume") | `gpt-6-luna` | $0.10 / $0.01 / $0.50 | **none**, low…max |
| (older) GPT-5.6 Sol / Terra / Luna | `gpt-5.6-sol` / `gpt-5.6-terra` / `gpt-5.6-luna` | $4/$20; $2/$12; $0.20/$1.20 | — |

- **Best quality: `gpt-6-astra`.** About **$0.031/photo** floor (input $0.016 + 300 out $0.015), and **~$0.05–0.06** with ~500 reasoning tokens at `low` **[assumption]**.
- **Cost-effective: `gpt-6.1-sol`.** About **$0.006 floor, ~$0.011** at `low`. `gpt-6-luna` with `reasoning.effort: "none"` costs ~**$0.0003/photo** and is a good cheap baseline. Its food quality is unknown.
- **Discounts:** Batch and Flex are ~50% off. "Fast" (formerly Priority) is ~2x.
- **Image input:** yes ("All latest OpenAI models support text and image input"). The `detail` parameter is `low`/`high`/`original`/`auto`. For `gpt-6-astra`, `auto` = `original`.
- **Structured output: "Structured Outputs".**
  - Responses API: `text: {format: {type: "json_schema", name, schema, strict: true}}`.
  - Chat Completions: `response_format: {type: "json_schema", json_schema: {name, strict: true, schema}}`.
  - The docs say it is supported from gpt-4o-2024-08-06 onward and recommend `gpt-6-astra` for new projects. I found no explicit per-model statement for GPT-6, but OpenRouter lists `structured_outputs` for all three GPT-6 models.
  - Strict-mode rules (every property in `required`, `additionalProperties: false`; optional fields as `["number","null"]`) come from prior knowledge. The "supported schemas" section was past the fetched part of the page **[unverified this pass]**.
- **Latency notes:** reasoning tokens add both latency and cost. For this task use `low` on Astra/Sol and `none` on Luna.

## Google Gemini (direct API)

Prices are from ai.google.dev/gemini-api/docs/pricing (paid tier). The output price **includes thinking tokens**.

| Model | ID | Status | $/MTok in / out | Thinking levels (default) |
|---|---|---|---|---|
| **Gemini 3.1 Pro** | `gemini-3.1-pro-preview` | **Preview** (only current Pro) | $2 / $12 (≤200K prompt) | low, medium, high (default high) |
| **Gemini 3.8 Flash** | `gemini-3.8-flash` | Stable, "most intelligent Flash" | $0.75 / $3.75 **through 2026-12-31**, then **$1.50 / $7.50 from 2027-01-01** | low, medium, high (default medium) |
| Gemini 3.5 Flash-Lite | `gemini-3.5-flash-lite` | Stable | $0.30 / $2.50 | minimal…high (default minimal) |
| Gemini 3.1 Flash-Lite | `gemini-3.1-flash-lite` | Stable | $0.25 / $1.50 | — |

- **Best quality: `gemini-3.1-pro-preview`.** About **$0.013/photo** at `thinking_level: low` and ~$0.025 at the default `high` **[assumption on thinking tokens]**. Caveats:
  - It is a preview model. The ID and behaviour can change.
  - `gemini-3.8-flash` is ~7 months newer and may match or beat it on vision. Test both.
  - The thinking docs' Go samples reference a `gemini-3.8-pro` that is not in the model table **[unverified; possibly imminent]**.
- **Cost-effective: `gemini-3.8-flash`.** About **$0.004–0.006/photo** at the 2026 promo price, roughly doubling in January. `gemini-3.5-flash-lite` costs ~$0.0015.
  - Flash-class Gemini has the best published cheap-model evidence. In the Nutrition5k bioRxiv preprint (Sterling 2026), Gemini 3.0 Flash was best of 10 approaches (CCC 0.767, MAE 80.7 kcal), and 3.1 Flash-Lite was close behind (CCC 0.754 at $0.59 per 1K images).
- **Image input:** yes on all models. Use `media_resolution` (`low`/`medium`/`high`/`ultra_high`) to trade tokens for detail. The default is 1,120 tokens.
- **Structured output: "structured output".**
  - The docs page now documents the Interactions API form: `response_format` with `mime_type: "application/json"` + `schema`. Examples use gemini-3.8-flash and gemini-3.1-pro-preview.
  - On `generateContent` the long-standing fields are `generationConfig.responseMimeType: "application/json"` + `responseJsonSchema` (full JSON Schema) or the older `responseSchema` (OpenAPI subset) **[field names from prior knowledge, not re-verified on today's page]**.
  - Supported keywords include `enum`, `minimum`/`maximum`, `minItems`/`maxItems`, `required` and `additionalProperties`. Unlike Anthropic's, numeric bounds are allowed.
- **Latency notes:**
  - Thinking cannot be turned fully off on 3.x Flash/Pro; the lowest level is `low`. Flash-Lite goes down to `minimal`.
  - `max_output_tokens` includes thinking, so set it generously (e.g. 4,000) or the JSON can come back truncated or empty.

## OpenRouter (one key, all models)

- **Fees:** no per-token markup ("We pass through the pricing of the underlying model providers without any markup"). Buying credits costs **5.5% by card (min $0.80)** or 5% by crypto. BYOK is free up to $25,000/month of list-price usage on pay-as-you-go, then 5%.
- **Access:** one OpenRouter key reaches every model below, including the big-3 IDs: `anthropic/claude-opus-5.5`, `openai/gpt-6-astra`, `google/gemini-3.1-pro-preview`, `google/gemini-3.8-flash`, `anthropic/claude-haiku-5.5`, `openai/gpt-6-luna`.
- **Structured output:** OpenAI-style `response_format: {type: "json_schema", json_schema: {name, strict: true, schema}}`.
  - Support is **per endpoint (provider)**, not per model. Set `provider: {require_parameters: true}` so a request only routes to providers that honour `response_format`.
  - Some providers treat the schema as a hint rather than a guarantee. The optional "Response Healing" plugin repairs malformed JSON on non-streaming calls.
  - Every candidate below lists `response_format` + `structured_outputs` in today's `/models` JSON. Each currently has only first-party provider endpoints: Alibaba for Qwen, xAI for Grok, Mistral for Mistral.
- **Latency:** OpenRouter adds a routing hop. I found no current published overhead figure **[unverified]**. Today's endpoint stats returned no latency/throughput values.

**Non-big-3 options with image input (live prices from `/api/v1/models`, 2026-10-13):**

| Model | ID | $/MTok in / out | Notes |
|---|---|---|---|
| **Qwen3.8 Max (0902 snapshot)** | `qwen/qwen3.8-max-0902` | $2 / $6 | 2.4T MoE; text+image+video; reasoning. Vendor-reported MMMU-Pro 82.3 (Alibaba, Aug 2026; no independent score found). `qwen/qwen3.8-max-prime` is the same model, higher-throughput SKU at $4/$12. |
| **Qwen3.8 Flash** | `qwen/qwen3.8-flash` | $0.15 / $0.47 | multimodal reasoning; cheapest credible non-big-3 |
| Grok 4.7 | `x-ai/grok-4.7` | $2 / $6 | text+image; positioned for coding/agentic work |
| Mistral Large 4 | `mistralai/mistral-large-4-0` | $0.68 / $2.09 | text+image |
| Kimi K3 | `moonshotai/kimi-k3` | $0.73 / $10 | 2.8T open-weight; expensive output if it reasons |
| Meta Muse Spark 1.3 / Muse Wonder | `meta/muse-spark-1.3` / `meta/muse-wonder` | $1.25/$4.25; $4/$20 | multimodal reasoning |
| GLM-5.3 Flash / GLM-5V Turbo | `z-ai/glm-5.3-flash` / `z-ai/glm-5v-turbo` | $0.026/$0.90; $1.2/$4 | |

- **Plainly: the best-quality option on OpenRouter is a big-3 model routed through it**, e.g. `google/gemini-3.1-pro-preview`, `anthropic/claude-opus-5.5` or `openai/gpt-6-astra`.
  - No current food-specific evidence puts any non-big-3 model ahead.
  - Older Qwen VLMs were mixed on food benchmarks. Qwen2.5-VL-72B was the best open model on CalorieBench (MAE 121 kcal vs GPT-4o-mini 88). Qwen3-VL-8B was poor on OmniFood nutrient MAPE but best on portion MAPE in some domains.
  - In general vision benchmarks, the Qwen family is the one non-big-3 family that sits near the top: Vals MMMU mirror Qwen3.6 Plus 86.0% vs Gemini 3 Pro 87.2%. Those entries are stale versions.
- **Best non-big-3 pick to include as the "challenger": `qwen/qwen3.8-max-0902`.** About **$0.005/photo** floor, ~$0.008 with reasoning **[assumption on image tokens]**.
- **Cost-effective non-big-3 pick: `qwen/qwen3.8-flash`.** About **$0.0004–0.0006/photo**. `mistralai/mistral-large-4-0` (~$0.002) is a reasonable second if Qwen disappoints.

## Benchmark / published evidence: is one model family clearly better at food?

**Short answer: no definite winner.** Rankings flip with model version, dataset and prompt. None of the published evals covers the October 2026 generation (Opus/Sonnet/Haiku 5.5, GPT-6, Gemini 3.8 Flash). Portion and mass is the dominant error for every model. Adding a text hint or a known weight helps far more than switching models.

| Source (date) | Models tested | Food/nutrition result |
|---|---|---|
| **OmniFood-Bench**, arXiv 2607.08423 (v1 2026-07-09, v2 07-17), built on MM-Food-100K | gpt-5.1, gemini-3-flash, claude-sonnet-4, qwen3-vl-8B, InternVL3.5-8B, Llama-3.2-11B-Vision | **gpt-5.1** had the lowest total-macro MAPE in all 4 domains (homemade 49.2%, restaurant 40.9%, packaged 80.1%, raw fruit/veg 122.7%). claude-sonnet-4 was second on homemade/restaurant (61.2/50.0%). gemini-3-flash was much worse (114.3/71.1%). Portion MAPE leader varied (claude-sonnet-4 on homemade 51.6%, qwen3-vl-8B on raw). Authors note a "Semantic-Physical Gap": near-human dish naming, "catastrophic failure in mass estimation". |
| **CalorieBench-80K / Food-R1**, arXiv 2606.04986 (2026-06-03) | Gemini-2.5-flash, GPT-4o-mini, Qwen2.5-VL-72B, Qwen3-VL-8B, InternVL3-8B, LLaVA-7B, FoodLMM, Food-R1 | Calories only. Best proprietary model: **GPT-4o-mini** (MAE 88.4 kcal, R² 0.57). Gemini-2.5-flash was worst (MAE 301.9, R² −5.77). The authors' fine-tuned Food-R1 (42.6) beat everything. No Claude. |
| **ACETADA**, arXiv 2507.07048 (v1 2025-07-09, v2 2025-10-03; IEEE BHI 2025) | GPT-4.1, GPT-4o, Claude-3.7-Sonnet, Gemini-2.5-Pro, Gemma-3-27B, Qwen2.5-VL-72B, LLaMA-3.2-90B, Janus-Pro-7B | With metadata: **GPT-4.1** had the lowest kcal error (153.2 kcal, 21.3%) and carbs (20.4 g). **Claude-3.7-Sonnet** was nearly tied on kcal (153.8) and best on fat (6.1 g). GPT-4o was best on protein (10.0 g). Gemini-2.5-Pro was worst of the closed models (carbs 26.7 g, 46.6%). GPS/time metadata cut MAE. A "Scale-Hint" prompt gave the best average kcal error. |
| Sterling et al., bioRxiv 2026.07.26.740845 (2026-07-29), Nutrition5k, 3,229 images; abstract only | Gemini 2.0/2.5/3.0 Flash, 3.1 Flash-Lite, GPT-4o/4o-mini/5-mini, Claude Haiku 4.5, Qwen2-VL-7B, FatSecret | **Gemini 3.0 Flash** best on calories (CCC 0.767, MAE 80.7 kcal). Cheap-tier comparison only; no flagship models. |
| Soyer et al., Diabetes Res Clin Pract 2026 (n=22 meals, T1D); abstract | ChatGPT-5.2, Gemini-3 Pro, Claude Sonnet-4.5 | Image-only: **Gemini-3 Pro** lowest carb MAE (6.55 g); **Claude** highest share within ±10 g (81.8%). Image + description: Gemini 2.14 g MAE. |
| Nutrients 2026 18(12):2017 (Claude-only); snippet | Haiku 4.5, Sonnet 4.6, Opus 4.6 | Sonnet ≈ Opus (MedAPE gap 1–3 points), both well ahead of Haiku. Sonnet 4.6 beat a published ChatGPT-5 study on SNAPMe protein/fat MAE. |
| Older 2025 studies (see `../On device meal photo macros/accuracy_evidence.md`) | GPT-4o/4.1/5, Gemini 2.5, Claude | Mixed: one 2025 study had Gemini worst (MAPE 64–110%), another had Gemini best. |

Takeaways for the test app:

- OpenAI models are the most consistent across these papers. They topped OmniFood (gpt-5.1), CalorieBench among proprietary models (4o-mini) and ACETADA (4.1).
- Claude is consistently a close second and often best on fat or "within ±10 g".
- Gemini swings from worst to best depending on version: 2.5 was poor, 3.x Pro/Flash did well in the diabetes study and on Nutrition5k.
- None of this is strong enough to skip testing all three. That is the point of the app.

## Suggested lineup for the experiment

Six to eight models cover it at under ~$0.15 per photo in total. Even 300 photos across all of them comes to tens of dollars at most.

1. `claude-opus-5-5` (effort low) and `claude-sonnet-5-5` (thinking `between_tools`)
2. `gpt-6-astra` (effort low) and `gpt-6.1-sol` (effort low)
3. `gemini-3.1-pro-preview` (thinking low) and `gemini-3.8-flash` (thinking low)
4. Via OpenRouter: `qwen/qwen3.8-max-0902` and `qwen/qwen3.8-flash`
5. Optional cheap baselines: `claude-haiku-5-5`, `gpt-6-luna` (effort none), `gemini-3.5-flash-lite`

Practical notes:

- Log `usage` (input, output and reasoning tokens) per call to replace my thinking-token assumptions with real numbers.
- Pin exact model IDs. Gemini 3.1 Pro is a preview, and Gemini 3.8 Flash pricing doubles on 2027-01-01.
- Keep the schema portable: all fields required, optional values as nullable, no numeric bounds (Anthropic rejects them). Validate ranges in Swift.

## Sources

- Anthropic: `claude-api` skill (model table cached 2026-10-06); [Models overview](https://platform.claude.com/docs/en/about-claude/models/overview.md); [Vision](https://platform.claude.com/docs/en/build-with-claude/vision.md); [Structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs.md)
- OpenAI: [Pricing](https://developers.openai.com/api/docs/pricing); [Models](https://developers.openai.com/api/docs/models); [Images & vision](https://developers.openai.com/api/docs/guides/images-vision); [Structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
- Google: [Pricing](https://ai.google.dev/gemini-api/docs/pricing); [Models](https://ai.google.dev/gemini-api/docs/models); [Media resolution](https://ai.google.dev/gemini-api/docs/media-resolution); [Thinking](https://ai.google.dev/gemini-api/docs/thinking); [Structured output](https://ai.google.dev/gemini-api/docs/structured-output)
- OpenRouter: `https://openrouter.ai/api/v1/models` and `/api/v1/models/{id}/endpoints` (pulled 2026-10-13); [FAQ / fees](https://openrouter.ai/docs/faq); [Structured outputs](https://openrouter.ai/docs/features/structured-outputs)
- Benchmarks: [OmniFood-Bench arXiv 2607.08423](https://arxiv.org/html/2607.08423v2); [Food-R1 / CalorieBench arXiv 2606.04986](https://arxiv.org/html/2606.04986v1); [ACETADA arXiv 2507.07048](https://arxiv.org/html/2507.07048v2); [Sterling bioRxiv](https://www.biorxiv.org/content/10.64898/2026.07.26.740845v1); [Nutrients 18(12):2017](https://www.mdpi.com/2072-6643/18/12/2017/htm) (403, snippet only); [BenchLM Vals MMMU](https://benchlm.ai/benchmarks/valsmmmu); [Qwen3.8 Max benchmarks (BenchLM)](https://benchlm.ai/models/qwen3-8-max)
