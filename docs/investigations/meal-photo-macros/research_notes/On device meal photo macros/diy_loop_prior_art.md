# Prior art in the DIY AID ecosystem: AI and photo-based meal carb/macro estimation (as of 2026-10-13)

Method note: GitHub issue, PR and comment data come from read-only `gh` CLI/API queries run 2026-10-13. Web sources come from WebSearch/WebFetch. Reddit could not be reached: the search tool refuses reddit.com, so the Reddit, Facebook and Discord sentiment for that question is missing. Every status claim (merged, closed, released) was checked against the GitHub API state.

## Loop "FoodFinder" (Taylor Patterson / taylorpatterson-T1D): what it does, providers, architecture, status, maintainer feedback, safety design

### Takeaway
FoodFinder was never merged into LoopKit. Four upstream PRs (July 2025 to February 2026) were all closed, the last two on 2026-05-09, with the author citing Loop's new CONTRIBUTING.md guidance against AI-heavy or vibe-coded PRs. It now lives in a downstream fork, "Loop (AID) PowerPack", and was earlier offered as an opt-in Loop and Learn customization. It is a cloud, bring-your-own-key (BYO-key) design: OpenAI, Anthropic, Google or any OpenAI-compatible endpoint. The safety model has six parts: never auto-bolus, pre-fill only, confidence score shown, all values editable, keys kept in the Keychain, and off by default. The same code was ported into iAPS and shipped there (see the iAPS section).

### Cited Findings
- **Origins (2023–2024).** Patterson first asked for OpenFoodFacts text, barcode and voice search in Loop's Add Carb Entry screen in LoopKit/Loop#1939, opened 2023-03-07 by `taylorpatterson007`. It was stale-closed 2023-07-22. He re-filed it as LoopKit/Loop#2244 on 2024-10-13, which is still open, citing Glooko's food entry screen as the model. Neither request mentioned AI. — [Loop#1939](https://github.com/LoopKit/Loop/issues/1939); [Loop#2244](https://github.com/LoopKit/Loop/issues/2244)
- **PR #2325, "feature: AI-Enabled Food Search" (2025-07-05 → closed 2025-07-20, not merged).**
  - Features: text, barcode, voice and AI image analysis that produces "comprehensive nutrition data and dosing suggestions via diabetic notes", plus menu reading in multiple languages.
  - Keys: the user supplies their own AI API keys, and setup guides are included.
  - Review: Marion Barker (Loop maintainer) found the bar code reader "pretty slick". She asked for an enable/disable setting that defaults to off, which Taylor added on 2025-07-14 (`foodSearchEnabled`, default false, with the medical disclaimer always visible). She requested changes several times: the PR included Taylor's developer ID, made stray LibreTransmitter and project-file changes, had missing arguments that broke the browser build, and conflicted with Favorite Foods (selecting a favorite stopped filling carbs on three test phones).
  - She also said food search is a per-user choice: some users prefer "a few Favorite Food listings and use a SWAG for the carbs", which is her own approach.
  - [Loop#2325](https://github.com/LoopKit/Loop/pull/2325)
- **PR #2329, "Food Search 2.0" (2025-07-20 → closed 2026-02-19, not merged).**
  - Added "Advanced AI Analysis including FPU analysis, and Dynamic Dosing recommendations", behind the Loop > Settings > Enable Food Search flag.
  - Marion maintained parallel loopandlearn branches (`modify_for_pr2329`, `prepare_for_customization_pr2329`) so it could be added as a customization.
  - 2025-08-30: "This PR is not suitable to be added to Loop as is"; users were pointed to the lnl-scripts customization.
  - 2025-10-08: "This PR will not build. There are modifications required to this and to LoopKit."
  - User report, 2025-10-17: Gemini broke because Google deprecated Gemini 1.5, "and this customization feature was hard coded to use that version". The workaround was Gemini's OpenAI-compatible endpoint with gemini-2.5-flash or -pro.
  - [Loop#2329](https://github.com/LoopKit/Loop/pull/2329)
- **PR #2404, "FoodFinder" (2026-02-11 → closed 2026-05-09, not merged).** The documented design:
  - Four input modes: OpenFoodFacts text/barcode, AI plate photo, voice/dictation, and menu/recipe OCR using on-device OCR followed by AI.
  - BYO key for an OpenAI-compatible, Anthropic Messages or Google Generative AI provider, stored in the iOS Keychain.
  - The user picks the model (examples given: gpt-4o, claude-sonnet-4-5, gemini-2.0-flash).
  - Analysis history kept 24h/7/14/30 days, plus Favorite Food thumbnails.
  - "AI-recommended absorption times with conservative model anchored to Loop's 3-hour default", capped at 5 h.
  - Advanced dosing notes (FPU, fiber, GI, insulin timing) behind a separate toggle that defaults off.
  - Footprint: 34 new files and about 29 lines of integration across existing files, with no LoopKit modifications.
  - [Loop#2404](https://github.com/LoopKit/Loop/pull/2404)
- **#2404 safety section (quoted design claims).**
  - "FoodFinder never boluses automatically. It only pre-populates the carb entry field — the user always reviews, edits, and confirms."
  - "Confidence scoring is displayed for every AI analysis (20–97% range). Low-confidence results are visually flagged."
  - All values are editable and treated as "starting points".
  - "No data leaves the device except the API call to the user's own configured AI provider."
  - [Loop#2404](https://github.com/LoopKit/Loop/pull/2404)
- **Beta feedback on #2404 (April 2026)** was UI bugs only: text overflow and Recent AI Analyses not persisting. No accuracy data was posted. — [Loop#2404](https://github.com/LoopKit/Loop/pull/2404)
- **Closure, 2026-05-09.** #2404 and the companion #2405 (LoopInsights, an AI therapy-settings advisor) were both closed by the author "per the new CONTRIBUTING.md guidance", with work moving to https://github.com/LoopPowerPack/LoopWorkspace. Taylor also closed his BolusPro (#2430), SiteAtlas (#2427), AutoPresets (#2402) and GraphDetailView (#2425) PRs. — [Loop#2404](https://github.com/LoopKit/Loop/pull/2404); [Loop#2405](https://github.com/LoopKit/Loop/pull/2405)
- **Loop's CONTRIBUTING.md** was added to LoopKit/LoopWorkspace on 2026-05-05, in commit c946433a, "Add CONTRIBUTING.md file, adapt from Trio". It says to "Use AI tools, if at all, as a support for small, well-understood tasks" and "Do not submit AI-heavy or 'vibe-coded' pull requests". It is a code-authorship policy, not a ban on the feature itself. — [LoopWorkspace CONTRIBUTING.md](https://github.com/LoopKit/LoopWorkspace/blob/main/CONTRIBUTING.md)
- **Current home: LoopPowerPack.** The GitHub org describes it as an "opt-in DIY Loop feature pack: FoodFinder, LoopInsights, AutoPresets, BolusPro, SiteAtlas, GraphDetailView". LoopPowerPack/Loop was last updated 2026-10-12, so it is active. There is also an older aggregate repo, TaylorJPatterson/Loop-AllFeatures ("Loop + AutoPresets + FoodFinder + LoopInsights", updated 2026-05-17). — [LoopPowerPack/LoopWorkspace](https://github.com/LoopPowerPack/LoopWorkspace); [TaylorJPatterson/Loop-AllFeatures](https://github.com/TaylorJPatterson/Loop-AllFeatures)
- **PowerPack developer docs** (`Documentation/FoodFinder/FoodFinder_DEVELOPER.md`):
  - Vision barcode detection, including QR, Data Matrix and PDF417.
  - A pre-AI crop UI.
  - A fast on-device OCR gate (`VNDetectTextRectanglesRequest`): when text density is high, the AI is told to focus on the food. This was added after a "pizza-on-paper-menu OCR confusion".
  - A 90-day local analysis history.
  - A "Personal Insight" card once the same meal has been logged at least twice.
  - "Models that refuse a temperature setting are deliberately unsupported."
  - A logged event payload that includes both `carbsGrams` and `originalAICarbs` plus `aiConfidencePercent`, so AI-vs-user corrections are tracked.
  - Single-frame analysis only, with no multi-angle support in v1.
  - [LoopPowerPack/Loop FoodFinder_DEVELOPER.md](https://github.com/LoopPowerPack/Loop/blob/main/Documentation/FoodFinder/FoodFinder_DEVELOPER.md)
- **Author's framing** (Substack, 2026-05-11):
  - FoodFinder's estimate is "an input, not a dosing decision", consumed by Loop's unmodified algorithm.
  - Toggles default OFF, with disclaimers at onboarding.
  - Runtime AI uses the user's own key, so data goes only to the chosen provider.
  - A dashboard "tracks the gap between AI estimates and user corrections". No numbers are reported.
  - The fork exists because upstream "decided AI-generated contributions don't fit".
  - [Why we built Loop PowerPack with AI (Substack)](https://taylor256.substack.com/p/why-we-built-loop-powerpack-with)
- **Customization status unclear.** The Loop and Learn "features in development" page fetched today no longer lists Food Search. It only lists Profiles Save & Load, Basal Lock, Negative Insulin Damper and Remote Window. Marion had linked a `#food-search` anchor there on 2025-10-08. — [Loop and Learn: features in development](https://www.loopandlearn.org/loop-features-in-development/); [Loop#2329 comment](https://github.com/LoopKit/Loop/pull/2329)

### Inferences
- Upstream Loop's objections were mostly about the PR rather than the idea: build hygiene, review burden, and AI-generated code under the new CONTRIBUTING rule. Marion's only feature-level asks were default-off and a settings toggle. There is no public LoopKit statement that photo-AI carb estimation is unsafe in principle. That contrasts with Trio's explicit statement (next section).
- Hard-coding a cloud model ID (Gemini 1.5) broke users when the vendor deprecated it. That is a real maintenance hazard of cloud BYO-key designs which an on-device model avoids.
- Logging `originalAICarbs` next to the confirmed carbs is the most reusable idea for measuring AI-vs-user deltas without keeping the photo.

### Gaps
- No accuracy or outcome data from FoodFinder beta users was found, whether in PR comments, the Substack post or the docs.
- LoopKit's Zulip discussions were not accessible, so private maintainer reasoning (for example from ps2) is unknown.
- Whether a Loop and Learn customization for Food Search still exists today is unconfirmed: the page no longer lists it.

## Trio (nightscout/Trio): PRs, issues, forks for AI food photo, food database or barcode, and maintainer stance

### Takeaway
Trio has merged no AI food feature, no food database and no barcode feature. The maintainers have an explicit, repeated stance. They will not accept anything that requires users to connect Claude or any other LLM. LLM-based carb recording or dosing prompts "won't land in Trio". Any future meal AI would be "ML-based, not LLM-based", and would come after the oref Swift port, with heavy safety clamps and a design document. The one food-input PR the team engaged with seriously (an OpenFoodFacts barcode scanner) was required to strip its AI parts, then closed in July 2026 as too large, vibe-coded and stale.

### Cited Findings
- **PR #881, "Add AI Insights (Claude) and 'quick add' carbs input buttons"** (zgoettsc, 2025-12-10 → closed 2025-12-11).
  - Mike Plante: "At this time, we are not accepting any PRs that require linking an LLM to use it."
  - dnzxy: "strong practical and philosophical concerns around AI usage for an app that does insulin dosing and just uploading a user's personal diabetes health data to a random LLM. Data privacy is not just a sham." He also asked for the problem / status quo / proposal questions to be answered.
  - [Trio#881](https://github.com/nightscout/Trio/pull/881)
- **PR #886 / #888, "AI Features Suite"** (2025-12-13). This was a Claude API suite including "Photo Carb Estimation — Camera-based carb estimation" and "Claude-o-Tune". #886 was closed because it targeted main. #888 was closed 2025-12-20. — [Trio#886](https://github.com/nightscout/Trio/pull/886); [Trio#888](https://github.com/nightscout/Trio/pull/888)
- **The team's canonical AI stance** (dnzxy, Trio#888, 2025-12-14), later cited from other threads:
  - "Photo Carb Estimation, Claude-o-Tune … either directly influence or would reasonably be expected to influence insulin dosing decisions. That is a line we cannot cross with a generic LLM integration."
  - "We will not accept anything into Trio that requires users to add Claude (or any other LLM) to the app at this point in time."
  - "LLMs are not capable of making or guiding insulin dosing decisions safely on their own … only with heavy safety clamps, extensive research, and well-reasoned, domain-specific models."
  - The ML roadmap comes after the JS-to-Swift oref port.
  - Trio is collaborating with "Syntactiq, Stanford Medical, HPI, UCDavis".
  - He asked for a "problem statement, safety model, user flow, or integration strategy".
  - [Trio#888 comment 3651397154](https://github.com/nightscout/Trio/pull/888#issuecomment-3651397154)
- **PR #874, "barcodescanner for quick carb entry of processed food"** (EJM0, 2025-12-04 → closed 2026-07-18, not merged).
  - Scope: OpenFoodFacts barcode scanning plus text search, with an edit/verify view before Add, an itemized meal list and a settings page. OpenFoodFacts login is recommended because anonymous text search is rate-limited.
  - Early on, Sam King (kingst) requested changes: "I'm concerned about the use of AI/ML here without any sort of design doc … anything that uses AI/ML, especially via cloud services, should have a well articulated safety and security discussion."
  - He also said: "Long term I'd like to see Trio move toward no meal announcements vs tools to help with meal announcements". He suggested a separate app talking to Trio over a universal link or other IPC, and starting with a short design doc.
  - Mike Plante, 2025-12-10: "Please strip the AI parts out."
  - EJM0 argued that his only remaining ML was openfoodfacts/nutrition-extractor, used for nutrition-label extraction rather than carb prediction. Mike's reply on 2025-12-16: "So please strip it out for this PR."
  - Mike tested it and called it "pretty cool". The UX notes asked for a visible barcode button and per-serving as well as per-100 g display.
  - Closed 2026-07-18 by t1dude: "It needs to be re-engineered … very hard to review … The code seems to be entirely vibe coded." A new PR is welcome.
  - EJM0 keeps fork branches `aibarcode` and `feature/mealmanager+noios26`.
  - [Trio#874](https://github.com/nightscout/Trio/pull/874)
- **Issue #953, "Ai for meals"** (salguccio, 2026-01-27 → closed not_planned 2026-01-30). A user had run a private AI-meal fork "for a few months". dnzxy pointed to the #888 stance and said the barcode scanner (#874) is "probably the extent to which this will go for Trio for the near future". — [Trio#953](https://github.com/nightscout/Trio/issues/953)
- **Issue #963, per-100 g presets** (2026-02 → closed not_planned 2026-04-20).
  - dnzxy, 2026-02-03: "this among other things is the reason why LLM based carb recording &/or dosing prompts won't land in Trio. Carb entries lead to dosing, and if said dosing is off, we are still talking a potentially deadly substance here."
  - Also: "if such features land in Trio, it will be ML-based, not LLM-based."
  - He said he does not think "it should be Trio's 'job' to maintain a food database internally", and that "oref is built to work well with *estimates*, not hyper-precise macro accounting".
  - JohnKitching noted in the same thread that iAPS had "an AI food integration under test in dev".
  - [Trio#963](https://github.com/nightscout/Trio/issues/963)
- **Issue #964, smart-scale carb capture** (closed not_planned 2026-09-05). dnzxy: "I personally think an AID should become more input agnostic/independent, rather than more". He said ML-driven preemptive dosing may come eventually. — [Trio#964](https://github.com/nightscout/Trio/issues/964)
- **Issue #268, Food Manager & Database** (2024-06-03 → closed 2025-05-15). dnzxy: "Feel free to PR something like this as a service integration … Not on the roadmap to include this." — [Trio#268](https://github.com/nightscout/Trio/issues/268)
- **PR #1052, Apple Health meal import** (accidental PR, 2026-04-04). dnzxy warned that "Importing CHO from Apple Health has caused many problems for Loopers … potential cause for overdosing, especially around meal entry deletion", and that Trio intentionally does not import carbs, fat or protein from Apple Health. — [Trio#1052](https://github.com/nightscout/Trio/pull/1052)
- **Trio's CONTRIBUTING.md** (the source Loop adapted from) says AI-assisted work is welcome only for "limited, well-understood tasks", and: "We do not accept pull requests that are largely AI-generated." — [Trio CONTRIBUTING.md](https://github.com/nightscout/Trio/blob/dev/CONTRIBUTING.md)
- **Other hits.** PR #962, "Ai carb entry" (gordolio, 2026-02-01), was opened and closed within a minute ("opened this by accident"), so no contents are known. Issue #804, favorite-food search, was stale-closed. — [Trio#962](https://github.com/nightscout/Trio/pull/962); [Trio#804](https://github.com/nightscout/Trio/issues/804)

### Inferences
- The proposed feature (on-device model, photo discarded, pre-fill and confirm) answers the stated privacy objection (no upload to a third-party LLM) and the BYO-key objection. It does not obviously answer dnzxy's broader statement that "LLM based carb recording … won't land". An on-device vision-language model is still an LLM. Framing it as on-device ML for food recognition plus a deterministic nutrition lookup may matter for acceptance.
- Before code, maintainers have consistently asked for four things: a short design document (kingst), answers to problem / status quo / proposal (dnzxy), a small and non-vibe-coded PR (t1dude, CONTRIBUTING), and conformance with Trio UI patterns (dnzxy on #874).
- kingst's separate-app-plus-IPC idea and dnzxy's "service integration" idea (#268) are recurring alternatives the team offered for food features.

### Gaps
- Trio Discord discussions are not public. dnzxy repeatedly moved conversations there, so the team's current thinking (for example on on-device Apple Foundation Models) is not observable.
- No triodocs.org page on AI or food features was found or checked. Search returned nothing relevant.
- There is no public statement on whether Apple's on-device model would count as "requiring users to add an LLM". The stated policy targets user-added cloud LLMs plus LLM-guided dosing generally.

## iAPS (Artificial-Pancreas/iAPS): AI meal, photo and food-search features

### Takeaway
iAPS is the one major DIY AID app that merged and shipped AI photo food analysis. It started from Taylor Patterson's Loop code (merged to dev 2025-09-11), was fully refactored by yurique (merged 2026-03-26) and shipped in v8.2.0 (2026-04-22). It is cloud-only with BYO keys for OpenAI, Claude and Gemini, plus OpenFoodFacts and USDA databases, and later gained voice entry. The Diabettech author (tim2000s) objected on safety grounds, citing his own unpublished research on LLM inconsistency.

### Cited Findings
- **Request.** Issue #1574, "AI-powered food recognition" (2025-08-25), asked for photo, barcode or text/voice input; external AI APIs (OpenAI, Anthropic) "or allow local models for privacy"; storage in Nightscout; and a fully optional feature. Jon-b-m (lead) replied that a PR was pending. — [iAPS#1574](https://github.com/Artificial-Pancreas/iAPS/issues/1574)
- **PR #1586, "AI Food Search by Taylor Patterson"** (Rig22): text database query, OpenFoodFacts barcode, "or by integrating OpenAI, Gemini or Claude AI". Merged to dev 2025-09-11. — [iAPS#1586](https://github.com/Artificial-Pancreas/iAPS/pull/1586)
- **Early bug.** Issue #1591 (2025-09-11): "AI food search" opened the camera and closed it again on iOS 26. — [iAPS#1591](https://github.com/Artificial-Pancreas/iAPS/issues/1591)
- **PR #1643, "AI Food search"** (Jon-b-m, "Ported from Loop by @rig22"). Web database barcode and text search, AI image analysis from camera or library, and a 24 h meal summary view. Merged 2025-12-03. PR #1728 (merged 2025-12-13) added combined AI searches, plus/minus buttons and a skip-save-as-preset setting. — [iAPS#1643](https://github.com/Artificial-Pancreas/iAPS/pull/1643); [iAPS#1728](https://github.com/Artificial-Pancreas/iAPS/pull/1728)
- **PR #1742, "ai rework"** (yurique, 2025-12-21 → merged 2026-03-26).
  - Code: "probably 80% less code". Prompts were extracted into sectioned assets with an "almost-typed output schema".
  - User settings for language, region and "nutrition standards authority", plus more models.
  - Per-100 g-centric nutrition.
  - Editable detected portions, with deletion of items.
  - The camera button opens the camera; a long tap selects from the library.
  - Optional text annotations as hints to the AI.
  - Simpler integration into Add Carbs ("removed the extra 'take over' step").
  - Future ideas: let the model return multiple candidate foods when uncertain so the user keeps one, and two-angle photos.
  - [iAPS#1742](https://github.com/Artificial-Pancreas/iAPS/pull/1742)
- **tim2000s's objection** (on #1742, 2026-03-26):
  - "With the best will in the world, this is a dangerous addition to an AID system. You cannot override the underlying model by prompting it … LLMs cannot verify their outputs."
  - His research reportedly found "40g of carbs [difference] on the same photo across 12 different submissions and three different sets of responses on what a photo contained".
  - He estimated the 40 g spread as "~75% error". Errors came from interpreting portion size and food content, grew with dish complexity, and only carbs were checked.
  - yurique replied that with temperature 0 he sees ±5–10% on the same photo (not a formal study), that "the algorithm will not blindly trust the announced carbs", and that LLMs are "NOT to be trusted blindly".
  - The PR was merged the same day.
  - [iAPS#1742](https://github.com/Artificial-Pancreas/iAPS/pull/1742)
- **Current code layout** (dev branch):
  - `Services/FoodSearch/AI/Providers/{Claude,Gemini,OpenAI}Protocol.swift` calling api.anthropic.com/v1/messages, generativelanguage.googleapis.com and api.openai.com/v1/responses, with per-model `temperature`.
  - `ImageCompression.swift` resizes images to a byte cap of 4,800,000.
  - The output schema has a per-item `confidence` of high/medium/low, plus `portion_estimate_size`, `visual_cues`, `assessment_notes`, `diabetes_considerations`, `glycemic_index`, macros per 100 g, and `image_type` of food_photo/menu_photo/recipe_photo.
  - Databases: OpenFoodFacts and USDA.
  - [iAPS FoodSearch source](https://github.com/Artificial-Pancreas/iAPS/tree/dev/FreeAPS/Sources/Services/FoodSearch)
- **Release.** v8.2.0 (2026-04-22) notes: "AI and barcode refactoring, by @yurique". — [iAPS releases](https://github.com/Artificial-Pancreas/iAPS/releases)
- **Follow-ons.**
  - #1839: AI error logging (merged 2026-04-05).
  - #1889: USDA database with personal API keys (merged 2026-05-21).
  - #1883: voice-activated meal entry (merged 2026-08-14). It uses on-device `SFSpeechRecognizer`, sends transcripts into the cloud AI pipeline, and forces Gemini into JSON mode for latency. The author's view: "voice is easier and faster, more accurate, and less AI expensive than taking a photo."
  - #1827: FDDB (German food database) importer, still open.
  - [iAPS#1883](https://github.com/Artificial-Pancreas/iAPS/pull/1883); [iAPS#1889](https://github.com/Artificial-Pancreas/iAPS/pull/1889); [iAPS#1827](https://github.com/Artificial-Pancreas/iAPS/pull/1827)

### Inferences
- iAPS is the most mature reference implementation of the full UX: itemized results, per-item confidence, editable portions, totals summary, then Add Carbs and bolus. It is also the only one with a public safety debate attached. Its schema (per-item confidence, visual cues, per-100 g macros times an estimated portion) is a strong template for the structured output of an on-device model.
- Separating "what food is it" (model) from "how many grams per 100 g" (database or model) from "how big is the portion" (model, user-editable) matches where tim2000s says the errors concentrate: portion and content interpretation.

### Gaps
- No iAPS user outcome or accuracy data was found.
- tim2000s's paper was described as "submitted for publication", and searches did not find it. Its venue and status as of October 2026 are unknown.
- How iAPS handles photo retention (whether images are saved with saved foods) was not fully verified. yurique mentions "images saved for foods", which suggests some photos persist with saved foods.

## AndroidAPS, xDrip+, Nightscout, Juggluco, Gluroo, Sugarmate, Tidepool: AI meal-photo features or plugins

### Takeaway
No AI photo meal estimation exists in AndroidAPS, xDrip+ or Nightscout core, and the GitHub searches found no PRs. Food-database ideas in AAPS date from 2021–2022 and are still open with no implementation. The AI-photo activity in this ecosystem is in adjacent third-party apps. Gluroo has photo estimates and imports doses from Loop and iAPS. CarbCam is Nightscout-adjacent and cloud multi-provider, and writes Nightscout notes rather than treatments.

### Cited Findings
- **AAPS #1105** (2021-12-29, open) asks for a meal calculator from the FOOD tab using Nightscout food data or OpenFoodFacts, with "nice to have — add a photo of the meal". No implementation. — [AAPS#1105](https://github.com/nightscout/AndroidAPS/issues/1105)
- **AAPS #2076** (2022-09-14, open) asks for USDA database integration. Milos Kozak (AAPS lead): "I don't think direct integration would help. UI for this would be complicated and during bolus (almost) nobody waste time". Others suggested external food-tracker apps posting to Nightscout, or an Android share intent. — [AAPS#2076](https://github.com/nightscout/AndroidAPS/issues/2076)
- **AAPS #4520** (2026-01-29, open, no replies) asks to integrate Yandex's "Alice" AI assistant for Russian speakers. It has nothing food-specific. — [AAPS#4520](https://github.com/nightscout/AndroidAPS/issues/4520)
- **Searches with no AI or food-photo results:** "food photo" in xDrip (NightscoutFoundation/xDrip) and "AI food" in nightscout/cgm-remote-monitor (gh search, 2026-10-13). — [xDrip repo](https://github.com/NightscoutFoundation/xDrip); [cgm-remote-monitor](https://github.com/nightscout/cgm-remote-monitor)
- **Gluroo.** Its App Store listing describes a photo-based food log that returns carbs, calories and sugar, and says it is used by more than 120,000 people. Gluroo says it can import doses from DIY Loop, iAPS and other supported systems. No accuracy data or model details are published. — [Gluroo App Store listing](https://apps.apple.com/us/app/gluroo-diabetes-logger/id1560748689)
- **CarbCam** (documented on the zehn.BE / 10be Nightscout-hosting site; the developer is not named on the page):
  - Workflow: photo, crop, hash-based precheck against a server cache, then cloud AI analysis.
  - Provider is user-selectable: Gemini, Claude, OpenAI, xAI Grok, Mistral or OpenRouter. No on-device model is described.
  - "Not used for model training."
  - Results are stored locally in SQLite. Meals sync to Nightscout as notes tagged CarbCam, not as treatments, so they do not affect Loop, AAPS or iAPS. A Share button can send carbs to AAPS, Loop, iAPS or Trio as an active treatment.
  - Published accuracy claims: ±20% for clear portions, ±30% for complex meals, ±40% or more for unusual dishes, ±5% for barcode products.
  - User overrides replace the AI value, and "the difference is stored for statistics".
  - Guidance: treat the estimate as a starting point, and verify for high-carb or hypo-risk boluses.
  - [CarbCam explained (10be)](https://ns.10be.de/en/carbcam-explained.html)

### Inferences
- The Android and Nightscout side has preferred integration over embedding: external apps post to Nightscout, or use Health Connect or share intents. That mirrors Trio's "service integration" and "separate app plus IPC" suggestions.
- CarbCam's split between a Nightscout "note" (informational) and an explicit "share as treatment" is a useful safety pattern: the AI output never becomes a dosing input without a deliberate user action.

### Gaps
- Nothing was found for Juggluco, Sugarmate or Tidepool, which may simply mean no such features exist. Sugarmate's status in 2026 was not checked.
- Gluroo's model provider, privacy handling and accuracy are undocumented in the sources reached.

## Commercial AID-adjacent products: AI meal-photo features and how they frame accuracy and safety

### Takeaway
The big CGM makers have shipped AI photo meal features, but framed them as logging and insight, not dosing. Dexcom's Smart Food Logging (G7 and Stelo, 2025) describes ingredients only. Abbott's Libre Assist (January 2026) predicts glucose impact on a three-color scale. No pump maker was found to ship photo-based carb estimation in its official app. Beta Bionics' iLet removes carb counting entirely through relative meal-size announcements. SNAQ, a third-party app, has RCT evidence in AID users.

### Cited Findings
- **Dexcom "Smart Food Logging"** (press release 2025-07-28): "AI will automatically identify the ingredients and populate the meal description". It launched on G7 earlier in 2025 and was added to Stelo with this release, on iOS and Android. The release does not mention carb or macro estimates, the AI vendor, feature-specific accuracy, dosing guidance or privacy terms. Dexcom calls G7 "the only prescription CGM in the U.S. to support photo logging". — [Dexcom IR press release](https://investors.dexcom.com/news/news-details/2025/Dexcom-Launches-Revolutionary-AI-Powered-Meal-Logging-Feature-Across-Glucose-Biosensing-Portfolio/default.aspx)
- **Abbott Libre Assist** (announced at CES, 2026-01-05). It is free inside the Libre app (US). It takes a meal photo or text, identifies ingredients and predicts glucose impact as green, yellow or orange, suggests swaps, and is meant to be used before eating. Afterwards it shows actual CGM data so users can compare predicted and actual response. Abbott describes it as generative AI. — [Abbott press release](https://abbott.mediaroom.com/2026-01-05-Abbotts-new-Libre-Assist-app-feature-tackles-a-top-need-for-people-living-with-diabetes-in-the-moment-food-decisions?asPDF=1); [US Pharmacist, 2026-02-03](https://www.uspharmacist.com/article/abbott-launches-aipowered-libre-assist-for-realtime-meal-guidance)
- **Abbott MyFreeStyle app.** Per search-result summaries, the listing advertises a photo breakdown of calories, carbs and protein, and states the app is not intended for "treatment decisions, and diabetes management". This is secondary and was not fetched directly. — [Apple App Store listing (as summarized)](https://apps.apple.com/app/id6501954823)
- **Pump makers.** A 2026 search found no official AI food-photo feature from Omnipod/Insulet, Tandem, Medtronic or Beta Bionics. Results were third-party apps only (SNAQ, carbAI, NetCarb, Insula, Gluroo). NetCarb's own listing says it is "NOT a medical device" and not for dosing. — [search results incl. NetCarb](https://play.google.com/store/apps/details?id=space.manus.netcarb&hl=en_US); [carbAI](https://play.google.com/store/apps/details?id=com.carbai.app)
- **iLet counterpoint.** Meal announcements need no carb counting. The user picks breakfast, lunch or dinner and "usual", "more" or "less" relative to their typical meal, and the system adapts doses from history. FDA cleared it in May 2022 for ages 6 and up. — [Beta Bionics meal announcements guide](https://www.betabionics.com/articles/meal-announcements); [diaTribe](https://diatribe.org/diabetes-technology/fda-clears-beta-bionics-ilet-bionic-pancreas-no-carb-counting-required)
- **SNAQ in AID users.** An RCT titled "App-based automated meal analysis in adults with type 1 diabetes using automated insulin delivery" reported, per the search summary, that three weeks of SNAQ use improved glucose control without changes to insulin dosing or carb intake. Use declined over time, and the benefit did not persist after stopping. SNAQ separately cites a 38% reduction in carb-estimation error versus self-estimates in 53 adults. The PMC page was blocked for direct fetch, so details are unverified. — [PMC12538901](https://pmc.ncbi.nlm.nih.gov/articles/PMC12538901/); [SNAQ carb counting](https://www.snaq.ai/carb-counting)
- **Diabettech's independent SNAQ test** (2025-08-08):
  - Portions were consistently underestimated: two 44 g toast slices were treated as one 44 g portion, and rice came out at about half.
  - Candy: 15 pieces counted versus 11 actual, at 10 g carbs per piece versus 5 g.
  - Recognition of non-packaged food was rated 1/5, and packaged food was about 50% accurate.
  - The app gives confident answers rather than admitting uncertainty. Corrections did not improve later estimates.
  - It works better on LiDAR iPhones, and the author criticized the lack of a warning about that.
  - "Blindly dosing … would have been a bit of a mess."
  - [Diabettech: Snaq review](https://www.diabettech.com/snaq-a-diabetes-ai-to-help-you-carb-count-badly/)

### Inferences
- Regulated CGM makers avoid presenting AI photo output as a carb number for dosing. Dexcom gives a description, Abbott a qualitative impact score, and Abbott's MyFreeStyle disclaims treatment use. A DIY feature that pre-fills grams into a bolus flow goes further than any regulated vendor has, which strengthens the case for strong confirmation UX and conservative framing.
- The iLet shows an alternative framing: estimating meal size relative to the user's usual meal is reportedly workable. A photo model could plausibly support "this looks like a larger-than-usual meal" more reliably than absolute grams. That is speculative.

### Gaps
- Dexcom's and Abbott's AI vendors and on-device versus cloud processing are not disclosed in the sources reached.
- Medtronic's Simplera/MiniMed app and the Tandem/Omnipod apps were not exhaustively checked beyond a single search; absence is not confirmed.

## Community discussion: are AI carb estimates trustworthy for dosing, and what concerns recur?

### Takeaway
Seven concerns recur across GitHub, blogs and maintainer statements:
- run-to-run inconsistency and hallucination (LLMs cannot self-verify);
- portion-size errors as the dominant failure;
- worse performance on complex or mixed dishes;
- privacy of uploading health or meal data to third-party LLMs;
- cloud model churn and the cost and maintenance of API keys;
- vibe-coded implementations that are hard to review;
- an AID philosophy favouring fewer meal inputs over more.

Supporters argue that AI beats unaided guessing, that the algorithm does not trust carbs blindly, and that the user confirms everything. Reddit and Facebook threads could not be accessed.

### Cited Findings
- **Inconsistency and hallucination.** tim2000s reported a 40 g spread (about 75%) on the same photo across 12 submissions, and different food identifications across users. He said "LLMs cannot verify their outputs, regardless of prompting." — [iAPS#1742](https://github.com/Artificial-Pancreas/iAPS/pull/1742)
- **Dosing risk.** dnzxy: "Carb entries lead to dosing, and if said dosing is off, we are still talking a potentially deadly substance here." A user in the same thread said they distrust AI carb counting ("AI told me 8 was an odd number"). — [Trio#963](https://github.com/nightscout/Trio/issues/963)
- **Privacy.** dnzxy objected to "uploading a user's personal diabetes health data to a random LLM. Data privacy is not just a sham." kingst said cloud AI/ML needs "a well articulated safety and security discussion". — [Trio#881](https://github.com/nightscout/Trio/pull/881); [Trio#874 review](https://github.com/nightscout/Trio/pull/874)
- **Maintenance and model churn.** Loop users lost Gemini when the hard-coded Gemini 1.5 was deprecated. — [Loop#2329](https://github.com/LoopKit/Loop/pull/2329)
- **AID philosophy.** kingst prefers "no meal announcements vs tools to help with meal announcements". dnzxy wants AID to be "more input agnostic". Milos Kozak: "during bolus (almost) nobody waste time". — [Trio#874](https://github.com/nightscout/Trio/pull/874); [Trio#964](https://github.com/nightscout/Trio/issues/964); [AAPS#2076](https://github.com/nightscout/AndroidAPS/issues/2076)
- **Supporting views.** A requester argued "More accurate carb counting → fewer postprandial spikes", reduced stress for caregivers, and better bolus accuracy. — [iAPS#1574](https://github.com/Artificial-Pancreas/iAPS/issues/1574)
- **User-reported success.** zgoettsc said the AI features "have already proven helpful for my management" and "No action is taken by the AI agent. No safety concerns." That is his own claim. — [Trio#881](https://github.com/nightscout/Trio/pull/881)
- **Practical friction.** A Breakthrough T1D forum thread notes that photographing can take longer than a mental estimate, and that salads and burritos are hard to judge from an image. Per the search summary, it was not fetched. — [Breakthrough T1D forum](https://forum.breakthrought1d.org/t/has-anyone-used-an-app-that-calculates-carbs-using-a-photo/74964)
- **Literature context** (per search summaries): photo-recognition apps (Foodvisor) underestimated carbs, with errors above 20 g in 30% of meals, but both tested apps still beat typical T1D self-estimation error. Twenty grams of error can substantially impair postprandial control. — [Springer, Diabetes Ther 2021](https://link.springer.com/article/10.1007/s13300-021-01082-2)

### Inferences
- The strongest technical objection (same-photo variance) is partly addressable with on-device deterministic decoding (temperature 0, fixed seed) and structured output. Portion-size error is not addressable that way and needs UX: editable portions, per-100 g times grams, a scale or reference prompt, and low-confidence flags.
- The privacy objection mostly disappears with an on-device model and photo discard, which is a meaningful differentiator from every DIY implementation found.

### Gaps
- Reddit (r/Trio, r/Loop, r/diabetes_t1), the Facebook Looped and Loop and Learn groups, and Discord are not reachable with the available tools. Community sentiment there is not captured.

## Apple Foundation Models framework or on-device models in diabetes apps

### Takeaway
No diabetes app, DIY or commercial, was found using Apple's Foundation Models framework or any on-device vision-language model for meal estimation. Every DIY implementation found (Loop FoodFinder/PowerPack, iAPS, Trio forks/PRs, CarbCam) uses cloud LLMs with user-supplied API keys. On-device processing in those apps is limited to Vision barcode and OCR detection and Apple speech recognition.

### Cited Findings
- **Loop FoodFinder.** Cloud providers only: OpenAI-compatible, Anthropic and Google. On-device parts are Vision barcode scanning and an OCR text-density gate. — [Loop#2404](https://github.com/LoopKit/Loop/pull/2404); [PowerPack FoodFinder_DEVELOPER.md](https://github.com/LoopPowerPack/Loop/blob/main/Documentation/FoodFinder/FoodFinder_DEVELOPER.md)
- **iAPS.** Cloud providers only: Claude, Gemini and OpenAI endpoints are hard-wired in the provider files. On-device `SFSpeechRecognizer` is used for voice. — [iAPS FoodSearch source](https://github.com/Artificial-Pancreas/iAPS/tree/dev/FreeAPS/Sources/Services/FoodSearch); [iAPS#1883](https://github.com/Artificial-Pancreas/iAPS/pull/1883)
- **Requests for local models.** The iAPS #1574 request explicitly suggested "allow local models for privacy", but this was not implemented. — [iAPS#1574](https://github.com/Artificial-Pancreas/iAPS/issues/1574)
- **Trio #874 ML component.** The only non-LLM ML proposed for Trio was openfoodfacts/nutrition-extractor, for nutrition-label extraction. It was removed at maintainers' request. Where it would have run (on-device or not) is unclear. — [Trio#874](https://github.com/nightscout/Trio/pull/874); [HF model](https://huggingface.co/openfoodfacts/nutrition-extractor)
- **Commercial apps.** A search for Foundation Models plus diabetes or carb estimation returned only generic carb apps (SNAQ with LiDAR 3D portion estimation, CarbsBud, Undermyfork), none citing Apple's on-device model. — [SNAQ App Store](https://apps.apple.com/us/app/snaq-diabetes-food-tracker/id1465916014)

### Inferences
- An on-device, photo-discarding implementation in Trio would appear to be the first of its kind in the DIY AID space. That novelty cuts both ways. It answers the privacy, API-key and model-deprecation objections raised against FoodFinder and iAPS. It has no prior field data, and the on-device model's food-recognition and portion accuracy is unvalidated (see the separate accuracy and Apple-stack notes).

### Gaps
- Whether the Apple Foundation Models framework (as of iOS 26/27) supports image input well enough for this use case is outside this note's scope; see `apple_on_device_stack.md`.
- No search of App Store listings for "Apple Intelligence" plus diabetes was exhaustive.
