# Measuring meal-photo → carbs/protein/fat accuracy: datasets, ground truth, metrics, harness

Research date: 2026-10-13. Scope: a personal n-of-1 experiment comparing Apple on-device Foundation Models (FM), a small on-device open VLM, and cloud models (Claude, GPT, Gemini), plus an optional offline public benchmark. This builds on `../On device meal photo macros/accuracy_evidence.md`, which covers the published accuracy numbers. This file covers how to measure. Tags: **[verified]** = I checked it directly (API call, file listing, or primary page). **[secondary]** = from a summary or search snippet. **[inference]** = my own reasoning.

## TL;DR

- **Offline benchmark:** use the **Nutrition5k overhead test split (507 dishes, CC BY 4.0)** and **ACETADA (806 smartphone before/after images, weighed, CC BY-NC 4.0)**. SNAPMe (CC BY-SA 4.0) is an optional third, with weaker self-reported ground truth. Don't treat MM-Food-100K, OmniFood-Bench, CalorieBench or JFB as ground truth: their macros are model-generated and then corrected by people, not weighed.
- **Personal set (primary evidence):** about **40–60 weighed meals** is enough to detect a **~4 g difference in carb MAE** between two models. About 100 meals are needed to detect ~3 g once you correct for comparing several models. Weigh each component by tare-and-add on the plate. Compute macros from USDA FoodData Central (FDC) or labels. Take two photos (a natural ~45° shot and an overhead shot). Write the one-line hint at capture time, before you see any model output.
- **Metrics:** MAE (g) per macro; mean signed error (bias) with 95% CI; % of meals within ±10 g and within ±20 g; % within max(10 g, 20%); Bland–Altman bias and limits of agreement plus a proportional-bias slope; MAPE only on meals with ≥10 g of truth, or wMAPE instead; run-to-run SD over 3 repeats; parse-failure and refusal rate; latency p50/p90; cost per image. Compare models with a paired Wilcoxon signed-rank test on per-meal absolute errors plus a paired bootstrap CI for the ΔMAE, Holm-corrected.
- **Harness:** a small Python script with a SQLite store. It is keyed by (image sha256, prompt sha, model key, params hash, repeat index), so it can resume and replay. It stores the exact image bytes sent, the raw response, the parsed values, latency, tokens and cost. Export to CSV. Borrow the adapter pattern from January's food-scan-benchmarks and the "immutable dated snapshot" pattern from foodvision-bench.
- **Mac as proxy:** valid for cloud models. Valid for the open VLM if you use the **same checkpoint and quantization** you will ship, and spot-check on the phone. Valid for Apple FM **only on macOS 27**, which ships the same on-device model plus image input via `fm respond --image` and the `apple_fm_sdk` Python package. **This Mac is on macOS 26.7.1** and would need upgrading. Latency and memory must always be measured on the iPhone.

---

## 1. Public datasets with images and gram-level macro ground truth

| Dataset | License | Personal eval OK? | Images | Macro GT (g) | How GT was made | Realism | Download |
|---|---|---|---|---|---|---|---|
| **Nutrition5k** (Google, CVPR 2021) | CC BY 4.0 | Yes | 5,006 dishes; overhead RGB-D on a subset; 507 overhead test dishes | Yes: per dish and per ingredient (mass, kcal, fat, carb, protein) | Weighed ingredients, incremental scans, USDA per-gram values | Lab rig in cafeterias, fixed overhead camera, mostly small or partial plates | Public GCS bucket (see below) |
| **ACETADA** (Purdue/Curtin, IEEE BHI 2025) | CC BY-NC 4.0 | Yes (non-commercial) | 806 before/after meal images, 152 adults | Yes: per item (served/after/consumed g, kcal, carbs, protein, fat) plus meal totals | Lab-prepared meals weighed to 0.1 g; dietitians assigned portions and macros per item | Real smartphone photos (mFR24 app) with EXIF time/GPS; controlled-feeding trial | Purdue page, after accepting the license |
| **SNAPMe** (USDA ARS / UC Davis, 2023) | CC BY-SA 4.0 | Yes | 3,311 photos (1,475 "before" non-packaged), 95 participants | Indirect: ASA24 food-record line items linked to photos | Participants' self-reported ASA24 records, not weighed | Free-living phone photos with a sizing marker | Ag Data Commons, 2.03 GB tar.gz |
| **MM-Food-100K** (Codatta) | OpenRAIL-M, non-commercial | Yes, but not as GT | 100,000 (of ~1M private) | Fields exist (`nutritional_profile` g, `portion_size`) | GPT-4o / Qwen generated, then crowd-corrected; portions estimated, not weighed | Real-world crowd photos; images hosted on an external host | HF `Codatta/MM-Food-100K` |
| **OmniFood-Bench** (arXiv 2607.08423) | Code MIT; data inherits MM-Food | As above | 1,208 (496 subset for closed models) | Inherits MM-Food | As MM-Food | Homemade / restaurant / packaged / raw | `github.com/PbRQianJiang/OmniFood-Bench` |
| **CalorieBench-80K** (Food-R1, arXiv 2606.04986) | Not stated | Unclear | ~80K (inferred from the name) | Calories plus CoT; macros not confirmed | Filtered from MM-Food-100K | As MM-Food | `hustvl/Food-R1` repo; dataset download not found |
| **January Food Benchmark (JFB)** | CC BY 4.0 (data and code) | Yes | 1,000 | Yes (kcal, carbs, protein, fat) | GPT-4o output corrected by a human annotator; not weighed; vendor-built | Real-world photos | `github.com/January-ai/food-scan-benchmarks` |
| **NutriBench** (ICLR 2025) | CC BY-NC-SA 4.0 | Yes | **None (text only)**; 11,857 meal descriptions | Yes (carb, protein, fat, kcal) | WWEIA (USDA) and FAO/WHO GIFT intake data | Natural-language meal descriptions | HF `dongx1997/NutriBench` |
| foodvision-bench `mini-231` | Code MIT | Unclear | 231 plates (iPhone 15 Pro + Pixel 8 Pro, overhead + 45°) | **kcal only** | Weighed per ingredient, FDC Foundation Foods | Real plates | Image availability not stated |

### Nutrition5k details
- **[verified]** The bucket is publicly readable over plain HTTPS with no gsutil or auth needed. Example: `https://storage.googleapis.com/nutrition5k_dataset/nutrition5k_dataset/imagery/realsense_overhead/dish_1556572657/rgb.png` (~400 KB). Each dish folder holds `rgb.png`, `depth_raw.png` and `depth_color.png`. Metadata files are `metadata/dish_metadata_cafe1.csv` (2.2 MB), `dish_metadata_cafe2.csv` and `ingredients_metadata.csv`. Splits are in `dish_ids/splits/{rgb,depth}_{train,test}_ids.txt`. The **depth (overhead) test split has 507 dishes**; the RGB test split has 709 (it includes side-angle-only dishes). Downloading the 507 overhead test RGB images is about 200 MB. The full tar.gz is 181.4 GB, mostly side-angle video. — [GitHub README](https://github.com/google-research-datasets/Nutrition5k); bucket listing via the GCS JSON API.
- **[verified]** CSV row format: `dish_id, total_calories, total_mass, total_fat, total_carb, total_protein`, followed by repeated `ingr_id, name, grams, calories, fat, carb, protein` groups. There is no ingredient-count column, so count the `ingr_` fields. The repo ships `scripts/compute_eval_statistics.py`, which computes MAE and percentage MAE per field from a predictions CSV.
- **[verified, computed from metadata]** The 507 overhead test dishes are small:
  - carbs: mean 19.7 g, median 15.4 g, p90 46 g; **37% < 10 g carbs and 25% < 5 g**
  - protein: median 11.4 g
  - fat: median 8.4 g
  - mass: median 161 g
  - ingredients: median 4

  This is because many entries are incremental partial plates. So MAPE on Nutrition5k blows up, and gram MAEs look smaller than they would for real meals. Filter to carbs ≥ 10 g, or report gram metrics only.
- **Caveats:**
  - The repo has been archived (read-only) since 2026-04-19. — [GitHub](https://github.com/google-research-datasets/Nutrition5k)
  - Labels are noisy. A human review found systematic ingredient omissions. — [Sterling et al. bioRxiv 2026](https://www.biorxiv.org/content/10.64898/2026.07.26.740845v1)
  - A community model card reports 2 corrupt test labels, e.g. a single 7,974 g "olives" ingredient. **[secondary]** — [CalorieK card](https://huggingface.co/Dralkh/CalorieK)
  - Papers disagree on whether to clean the data. DPF-Nutrition kept the bad images for comparability; another paper excluded them. — [DPF-Nutrition](https://arxiv.org/pdf/2310.11702); [depth adaptation](https://arxiv.org/pdf/2208.12153)
  - The cafeterias are Californian, so cuisine coverage is narrow.
  - The overhead camera rig is not how a phone photo looks.

### ACETADA details
- **[verified]** The dataset page describes the study:
  - a controlled-feeding randomized crossover with 152 adults in Perth
  - lab-prepared meals unobtrusively weighed to 0.1 g
  - photos taken with the mFR24 smartphone app, with timestamp and GPS in EXIF
  - dietitians enumerated the items and assigned portion weights and macros

  The data is one CSV, `ACETADA-HF-dataset.csv`, with `before_*` and `after_*` image paths. Per item (1–15) it has `_before_portion_g`, `_after_portion_g`, `_consumed_g`, `_energy_kcal`, `_carbs_g`, `_protein_g` and `_fat_g`, plus `total_*` columns, `meal_type` and `participant_id`. The license is CC BY-NC 4.0. — [ACETADA page](https://skynet.ecn.purdue.edu/~coburn6/ACETADA/); [arXiv 2507.07048](https://arxiv.org/abs/2507.07048)
- **Check before use:** confirm whether the item macro columns refer to the **served** or the **consumed** amount. Pair the "before" image with served macros; scale by `before_portion_g` if needed. The page says the before-meal image gives the upper bound.
- The arXiv paper also reports a [secondary] finding: adding contextual metadata (time, location, food item names) to prompts lowers MAE and MAPE. That is relevant to the "hint" arm.
- Practical note: the Purdue server's TLS chain failed verification for one fetch client (WebFetch); `curl` and browsers worked.
- This is the closest public match to "a phone photo of a real meal, with weighed macros".

### SNAPMe details
- **[verified via figshare API]** Ag Data Commons item 24856449 is licensed CC BY-SA 4.0 and contains a single `snapme_db_09Dec2022.tar.gz` (2.03 GB). It has 3,311 photos: 1,475 before / 1,436 after of non-packaged food, plus 203 package fronts and 196 ingredient labels. There are 275 ASA24 records from 95 participants, and each ASA24 line item is linked to its photo. A sizing marker is in frame. — [Ag Data Commons](https://agdatacommons.nal.usda.gov/articles/dataset/SNAPMe_A_Benchmark_Dataset_of_Food_Photos_with_Food_Records_for_Evaluation_of_Computer_Vision_Algorithms_in_the_Context_of_Dietary_Assessment/24856449); [Nutrients 2023 paper](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10708545/)
- Ground truth is self-reported ASA24 (FNDDS nutrients), **not weighed**. That makes it noisier than ACETADA. It is still useful as a realistic free-living test of robustness and of bias direction.

### Datasets to avoid as ground truth (fine for robustness checks)
- **MM-Food-100K:**
  - It is non-commercial (OpenRAIL-M).
  - Its macros come from GPT-4o / Qwen output corrected by the crowd, and its portions are estimated. — [HF dataset card](https://huggingface.co/datasets/Codatta/MM-Food-100K); [arXiv 2508.10429](https://arxiv.org/abs/2508.10429)
  - Scoring a GPT model against GPT-derived labels is circular.
- **OmniFood-Bench** (1,208 samples curated from MM-Food) reports only MAPE (portion and nutrition profile). Its README warns that some file names don't match the model actually called. — [arXiv 2607.08423](https://arxiv.org/html/2607.08423); [GitHub](https://github.com/PbRQianJiang/OmniFood-Bench)
- **CalorieBench-80K** focuses on calories. I found no confirmed macro labels and no dataset download. — [arXiv 2606.04986](https://arxiv.org/abs/2606.04986)
  - The Food-R1 model weights (`zy12123/Food-R1`, qwen3_vl architecture, Apache-2.0) could be a food-tuned candidate for the "small open VLM" slot. Its size and on-device viability are unverified. **[secondary]**
- **JFB:** labels are GPT-4o output corrected by a human; the leaderboard is vendor-built. — [arXiv 2508.09966](https://arxiv.org/html/2508.09966v1)
- **foodvision-bench:** the ground truth is weighed but covers kcal only. Image availability is unclear. The leaderboard reads as promotional: PlateLens is #1 everywhere, its replicated figure matches its vendor figure exactly, the maintainers are anonymous, and numbers are inconsistent between sections. Borrow its harness ideas, not its numbers. — [GitHub](https://github.com/foodvision-bench/foodvision-bench)

### NutriBench (text-only)
- License CC BY-NC-SA 4.0; 11,857 meal descriptions in v2. — [arXiv 2407.12843](https://arxiv.org/html/2407.12843v6); [HF](https://huggingface.co/datasets/dongx1997/NutriBench)
- Not an image benchmark. It is useful for a "hint-only, no image" baseline arm, which shows how much the photo adds beyond the description.

### Not found or unverified
- DonateAndLearn: the phone-photo set from Mu et al. 2025. Availability is unknown (PMC served a CAPTCHA).
- No other 2025–2026 public dataset was found that combines **smartphone photos, weighed ground truth, and per-macro grams** beyond ACETADA.
- Small Nutrition5k subsets on HF exist (e.g. `madroid/nutrient5k-test-100`), schema unverified. Pull from the official bucket instead.

**Recommendation [inference]:**
- Offline benchmark = Nutrition5k overhead test filtered to carbs ≥10 g (~320 dishes) + all ACETADA before-images (806).
- At ~1,100 images × 5 models × 3 repeats (~17k calls), cloud cost is roughly tens of dollars. Reference point: Sterling 2026 lists Gemini 3.1 Flash Lite at $0.59 per 1K images. Use provider batch APIs where offered.
- Report the two datasets separately. Never pool them with the personal set.

## 2. Building a personal ground-truth set

### Weighing protocol (tare-and-add)
1. Put the empty plate or bowl on the scale and tare.
2. Add one component at a time, recording the delta in grams after each (e.g. rice 182 g, chicken 121 g, sauce 38 g). The plate never leaves the scale. Use a scale with 1 g resolution, or 0.1 g for small items like sauces and oil.
3. Record cooking fat separately. Weigh the oil bottle before and after, or measure by spoon, and assign it to the dish. Fat is the macro photos miss most, so this matters (see `accuracy_evidence.md` Q2).
4. For batch recipes, use the **yield method**:
   - Weigh the raw ingredients and compute total macros.
   - Weigh the whole cooked batch.
   - Portion macros = batch macros × (portion g / cooked batch g).

   Cronometer's own staff recommend the equivalent: a negative "water" ingredient equal to the cooking loss, or a cooked-weight serving size. — [Cronometer forum](https://forums.cronometer.com/discussion/3915/custom-recipe-raw-vs-cooked-weight)
5. Keep the scale display **out of the photo**. Otherwise the model can read the grams.
6. Ground truth = food on the plate as photographed. Leftovers don't matter for this experiment.

### Computing macros
- **USDA FoodData Central API [verified]:**
  - Base URL: `https://api.nal.usda.gov/fdc/v1/`
  - Endpoints:
    - `GET/POST /foods/search` (`query`, `dataType` as an array or a comma list, `pageSize`)
    - `GET /food/{fdcId}`
    - `GET/POST /foods`
    - `/foods/list`
  - Key: free data.gov key from `api.data.gov/signup`. Keep it out of git; keys found in public repos are deactivated.
  - Rate limits: 1,000 req/h per IP; DEMO_KEY 30/h and 50/day.
  - License: public domain (CC0); credit FDC as the source. — [FDC API guide](https://fdc.nal.usda.gov/api-guide)
  - Nutrient IDs (checked with a live call; SR Legacy values are per 100 g):
    - protein `1003` (number 203)
    - total fat `1004` (204)
    - **carbohydrate by difference `1005` (205)**, which includes fiber, so it is total carbs
    - energy `1008` (208)

    Foundation Foods entries sometimes give carbs "by summation" or energy by Atwater-specific IDs instead. Check for those and fall back to them.
- **Which FDC data type to use:**
  - **Foundation Foods:** analytical data, but limited coverage. Prefer it when the food exists there.
  - **SR Legacy:** frozen in 2018, broad coverage, and has explicit "cooked" entries. It's the workhorse. Match the prep state you actually weighed (e.g. "Rice, white, … cooked").
  - **Survey (FNDDS):** "as eaten" mixed dishes. Use it only when you can't decompose a dish.
  - **Branded:** label-derived. Prefer the physical label in hand.
- **Labels:** FDA compliance allows naturally occurring carbs and protein to come in at ≥80% of the declared value, and fat and calories at ≤120%. Rounding is also coarse. Treat label-based components as about ±20%. — [21 CFR 101.9(g) summary](https://www.fda.gov/regulatory-information/search-fda-guidance-documents/guidance-industry-guide-developing-and-using-data-bases-nutrition-labeling); [FDA small-amounts guidance](https://www.hhs.gov/guidance/sites/default/files/hhs-guidance-documents/FDA/FDA_s-Policy-on-Declaring-Small-Amounts-of-Nutrients-and-Dietary-Ingredients-on-Nutrition-Labels-%28PDF%29.pdf)
- **Cronometer:**
  - Fine as a calculator. It uses NCCDB and USDA SR28 data, and you choose entries by prep state.
  - NCCDB is licensed, not public, so you can't reproduce its numbers outside Cronometer. NCCDB and USDA entries can disagree substantially for the same food.
  - For an auditable set, store FDC IDs in your own table, with Cronometer as a cross-check at most. — [Cronometer databases](https://cronometer.com/features/accurate-databases.html); [forum](https://forums.cronometer.com/discussion/6477/nccdb-or-usda)
- **Ground-truth quality tier:** record one per meal.
  - **A** = every component weighed and mapped to FDC
  - **B** = includes label-based packaged items
  - **C** = restaurant with published chain nutrition (no weighing)

  Headline results should come from A+B. Report C separately.
- **[inference]** Even the reference has noise: food composition varies, scales have ±1 g resolution, and FDC entries don't match your exact food. An MAE difference of 1–2 g between models is below what this set can resolve.

### Photo protocol
- **P1 (primary): a natural handheld shot** at about 45° from your seat, framed the way you would in the real app. This is what the product will actually see.
- **P2: overhead** (~90°), whole plate in frame.
  - Overhead views lose height and hide stacked food.
  - Oblique views recover height but foreshorten.
  - No head-to-head study of phone angles was found, so test both. — [AFINI-T occlusion note](https://arxiv.org/pdf/2112.04608); [DietVision 45° rationale](https://cs.nyu.edu/media/publications/Diet_Vision_2021_Technical_Report_PKqc2Lj.pdf)
- **Reference object:** leave the normal cutlery next to the plate and don't add a special card. A size reference did not help GPT-4o on composite meals (46.7% → 43.3% within ±10 g, Johansen JDST 2026). Add a card only on an optional subset if you want to test it.
- **Lighting:** normal eating conditions, no flash, avoid strong backlight. Shoot both photos within a minute.
- **Image files:**
  - Keep the original HEIC.
  - The harness derives a **canonical JPEG** with fixed long edge (e.g. 1024 or 1536 px), fixed quality, EXIF orientation applied, GPS stripped.
  - Every model gets the same bytes, identified by sha256. Apple FM token cost scales with image size, so fix this early.
- **Hint:** write it **at capture time, before you see any model output**, exactly as you'd type it in Trio. Example: "chicken stir-fry with rice, about a cup of rice". Rules:
  - No grams you only know because you weighed the food. Record a `hint_contaminated` flag if you couldn't avoid it.
  - Store the hint in its own field, so every image runs as **photo-only**, **photo + hint** and, optionally, **hint-only (no image)**.

  This gives a clean within-model measure of what the hint adds. In the literature that uplift is the single largest effect: Soyer 2026 MAE fell from 6.55 g to 2.14 g, and Tecce 2025 MAPE from 34.8% to 13.7%.
- **Meal mix:** cover what you actually eat, plus deliberate hard cases (~20%): sauces, oil-heavy dishes, desserts, sweetened drinks, mixed bowls. Tag `meal_type` (breakfast/lunch/dinner/snack/drink) and `setting` (home/restaurant).

### How many meals?
[inference; standard paired-design power: n ≈ ((z₁₋α/₂ + z₀.₈) · SD_diff / Δ)² × 1.05 for Wilcoxon efficiency, + 2]

Here SD_diff is the SD of the per-meal difference in absolute carb error between two models. Published per-meal absolute-error SDs are about 7–16 g (e.g. Lian 2026: 8.7 ± 7.4 g; Joubert 2026: 18 ± 16 g). Two models tend to fail on the same hard meals (correlation ρ ≈ 0.5), so SD_diff ≈ σ, i.e. about 8–10 g.

Meals needed for 80% power, by SD_diff and the MAE difference Δ you want to detect:

| SD_diff | Δ 2 g | Δ 3 g | Δ 4 g | Δ 5 g | Δ 6 g |
|---|---|---|---|---|---|
| α 0.05, 8 g | 134 | 61 | **35** | 23 | 17 |
| α 0.05, 10 g | 208 | 94 | 54 | 35 | 25 |
| α 0.005 (Holm, ~10 pairs), 8 g | 226 | 101 | **58** | 38 | 27 |
| α 0.005, 10 g | 351 | 157 | 89 | 58 | 41 |

- **Bottom line:** 30–40 meals can show a big gap (≥5 g, e.g. a frontier cloud model vs a 2B on-device VLM). Separating close competitors (3–4 g) across 5–6 models needs about **60–100 meals**. Differences of 1–2 g between top cloud models aren't resolvable in a personal set; treat them as ties.
- **Precision of a single model's MAE** (SD of absolute error about 8 g): the 95% CI half-width is about ±2.9 g at n=30, ±2.2 g at n=50 and ±1.6 g at n=100.
- **Per-meal-type breakdowns** with fewer than ~15 meals per cell are descriptive only. Don't run significance tests on them.
- **Workflow:** collect in waves. After ~30 meals, run everything and look at the per-meal paired differences, compute SD_diff from your own data, then decide how many more meals you need.

## 3. Metrics to report, and why

All metrics are per macro (carbs, protein, fat) plus derived kcal, per model × input condition (photo-only, photo+hint, hint-only).

**Accuracy**
- **MAE (g)** with a bootstrap 95% CI, plus median absolute error. This is the primary metric, in the units that drive dosing.
- **Mean signed error (bias)** with a 95% CI. Direction matters: carb overestimation leads to overbolus. Studies disagree on direction (ChatGPT-5 +2.8 g in Lian 2026; Gemini −1.05 g in Soyer 2026).
- **% within ±10 g** (carbs). This is the clinical threshold for paediatric guidance and the Smart 2012 dosing study.
- **% within ±20 g**, used by Joubert 2026.
- **% within max(10 g, 20%)**, a scale-aware composite. For protein and fat also report ±5 g / ±10 g.
- **MAPE caveat:** percentage error is undefined or explodes for small truths (Hyndman & Koehler 2006). Nutrition5k has 25% of dishes under 5 g carbs. Report MAPE only for truth ≥ 10 g, or use **wMAPE = Σ|e| / Σtruth** (JFB's metric). — [Hyndman & Koehler, IJF 2006](https://www.doi.org/10.1016/J.IJFORECAST.2006.03.001)
- **Bland–Altman:**
  - bias ± 1.96 SD limits of agreement
  - a plot of (pred − truth) against truth, or against the mean
  - a regression slope for proportional bias; NutriDish slope −0.09 = overestimates small meals and underestimates large ones

  Bland & Altman, Lancet 1986, DOI 10.1016/S0140-6736(86)90837-8 (cited from memory). Lin's CCC is optional (Sterling 2026 used it).
- **FPU-relevant [inference]:** error in (9·fat + 4·protein) kcal, because Trio's fat-protein units feed extended carbs. A model can be fine on carbs and poor on FPU.

**Reliability**
- **Run-to-run:** for each image, run **3 repeats** at the settings you'll actually ship. Report within-image SD and range per macro and the median CV. Wang/Lane/Waki (JMIR Diabetes 2026) found variability "nonnegligible" even with deterministic settings, using 60 runs per image.
  - The **primary accuracy metric** is the mean over repeats of |error|, which is the expected single-shot error the user would get.
  - Also report a **median-of-3 ensemble** as a separate "variant", in case the app aggregates.
- **Apple FM** has `GenerationOptions(sampling: .greedy)` for repeatable output. It is deterministic only for the same model version (OS build) and session state. — [WWDC25 / Kodeco summary](https://www.kodeco.com/ios/paths/apple-ai-models/48744203-apple-foundation-models/02-using-apple-foundation-models/03)
- **Failure rates:** parse failures (invalid JSON or schema), refusals and guardrail trips, and timeouts. Count these as failures, not missing data. Report them, and score them with a fallback (e.g. a fixed error of "truth" g, as if the user entered 0) so they aren't silently dropped. Apple FM guardrail false positives have been reported (see `apple_on_device_stack.md`).

**Operational**
- Latency p50/p90. On-device needs cold (first load) and warm separately, plus time-to-first-token if streaming.
- Peak memory, on iPhone only.
- Input/output tokens and cost per image (cloud). On-device and PCC have no cloud cost, but PCC has a daily quota.

**Breakdowns:** by meal type, setting (home/restaurant), ground-truth tier, simple vs composite, and photo angle (P1 vs P2).

**Paired statistics**
- **Two models (or photo-only vs photo+hint within one model):**
  - **Wilcoxon signed-rank** on per-meal |error_A| − |error_B|.
  - **Paired bootstrap** (resample meals, 10,000 reps) for the 95% CI of ΔMAE and Δ(% within ±10 g).
  - McNemar's test for the ±10 g hit/miss comparison.
- **More than two models:** Friedman test across models, then pairwise Wilcoxon with **Holm** correction (Demšar's recommendation; Benavoli 2016 argues for Wilcoxon over Nemenyi). — [Demšar, JMLR 2006](https://www.jmlr.org/papers/v7/demsar06a.html)
- Resample at the **meal** level, not the run level. Repeats are not independent meals.

## 4. Eval harness design

### Data model (SQLite; one DB per project, with CSV export views)
```
meals(meal_id PK, captured_at, meal_type, setting, cuisine, composite BOOL, gt_tier, 
      gt_carbs_g, gt_protein_g, gt_fat_g, gt_kcal, gt_mass_g, notes)
components(meal_id FK, idx, name, grams, source ENUM(fdc,label,recipe,chain), fdc_id, 
           per100_carb, per100_prot, per100_fat, carbs_g, protein_g, fat_g)
images(image_id PK = sha256 of canonical bytes, meal_id FK, role ENUM(p1_45deg,p2_overhead,...),
       original_path, canonical_path, long_edge_px, jpeg_quality, has_ref_object)
hints(meal_id FK, hint_text, written_at, contaminated BOOL)
prompts(prompt_id PK = sha256(system+template+schema), version_label, system_text, 
        user_template, output_schema_json, created_at)
models(model_key PK, provider, model_id (dated snapshot), runtime (api|mlx-vlm|mlx-swift|apple-fm|fm-cli),
       quantization, device, os_build, app_or_harness_version)
runs(run_id PK, batch_id, image_id, input_mode ENUM(photo,photo_hint,hint_only), prompt_id, model_key,
     params_json (temperature, top_p, max_tokens, seed, sampling, reasoning_effort), params_hash,
     repeat_idx, started_at, latency_ms, ttft_ms, input_tokens, output_tokens, cost_usd,
     status ENUM(ok,parse_fail,refusal,timeout,error), raw_response TEXT, 
     pred_carbs_g, pred_protein_g, pred_fat_g, pred_kcal, pred_items_json, error_text, harness_git_sha,
     UNIQUE(image_id, input_mode, prompt_id, model_key, params_hash, repeat_idx))
```
- **The UNIQUE key makes it resumable.** Replay = "insert any missing rows". Re-running a batch never double-counts, and a new prompt version or model snapshot simply creates new rows.
- **Pin dated model snapshots** for cloud models. Record the **OS build** for Apple FM, because the model changes with OS updates. Never overwrite rows: corrections become a new `batch_id` (the immutable dated-snapshot rule from foodvision-bench).
- **Same bytes to every model:** the runner reads `canonical_path`, never the HEIC. For on-device runs on the phone, either ship the canonical JPEGs to the device or have the app log the sha256 of what it actually fed the model, and join on that.
- **One output schema** for all models: `{items:[{name, grams, carbs_g, protein_g, fat_g}], total:{carbs_g, protein_g, fat_g, kcal}}`. Use structured outputs where available (Apple `@Generable` / `fm --schema`; JSON-schema modes in the cloud APIs). Parse the totals and also keep the items. Store the raw text either way.
- **Retry policy:** retry transport errors (429, 5xx) with backoff. **Don't retry** parse failures or refusals; they are results.
- **Batch and cost:** use concurrency limits per provider. Provider batch endpoints (Anthropic Message Batches, OpenAI Batch, Gemini batch) are typically discounted, so check current pricing. Compute cost from token counts × a pinned price table stored alongside the run.
- **Exports:**
  - `runs_long.csv`: one row per run with the ground truth joined.
  - `meal_model_wide.csv`: per meal × model × mode, mean of repeats, abs error, signed error.
  - `summary.csv`: metrics with CIs.
- **Analysis:** a notebook or script reads the CSVs, so analysis stays separate from collection.

### Existing code worth borrowing
- **Nutrition5k `scripts/compute_eval_statistics.py`:** reference MAE and %MAE computation for Nutrition5k-format CSVs. — [GitHub](https://github.com/google-research-datasets/Nutrition5k)
- **January `food-scan-benchmarks`** (MIT code):
  - Adapter interface `analyse(image) -> FoodAnalysis`, with LiteLLM routing across providers.
  - Async evaluation with per-item timing.
  - wMAPE metric, CSV export, `--max-items` smoke tests. — [GitHub](https://github.com/January-ai/food-scan-benchmarks)
- **OmniFood-Bench** (MIT): one eval script per model, JSONL raw outputs, MAPE summaries. Useful mainly for its prompt and parsing examples. — [GitHub](https://github.com/PbRQianJiang/OmniFood-Bench)
- **foodvision-bench** (MIT): an adapter registry, bootstrap 95% CIs, dated immutable JSON snapshots, and a hash-locked test split. Copy the patterns, not the leaderboard. — [GitHub](https://github.com/foodvision-bench/foodvision-bench)
- **Apple tooling (macOS/iOS 27):**
  - The **Evaluations framework** in Xcode 27: datasets of `ModelSample`, Metrics and Evaluators, aggregation. Useful if part of the harness runs in Swift on the phone. — [WWDC26 "Meet the Evaluations framework"](https://nonstrict.eu/wwdcindex/wwdc2026/298/); [macOS 27 what's new](https://developer.apple.com/macos/whats-new/)
  - **`apple_fm_sdk`** (pip) and the **`fm` CLI**, preinstalled on macOS 27. Example: `fm respond "<prompt>" --image meal.jpg --schema macros.json [--model pcc]` returns schema-constrained JSON. The Python SDK supports image input and `@fm.generable` structured output; its image-input code and sampling options weren't shown, so check the docs. The example also shows **PCC accepting an image**, which answers an open question in `apple_on_device_stack.md` (via CLI at least). — [WWDC26 session 334](https://developer.apple.com/videos/play/wwdc2026/334/); [python-apple-fm-sdk](https://github.com/apple/python-apple-fm-sdk)
  - macOS/iOS 27 Foundation Models also accept third-party providers (Claude, Gemini) through the `LanguageModel` protocol. A Swift harness could therefore drive Apple FM, PCC and cloud models through one session API. Still, call the cloud models through their native APIs too, to make sure the abstraction doesn't alter the request. — [macOS 27 what's new](https://developer.apple.com/macos/whats-new/)
- **General LLM eval tools** (promptfoo, Inspect AI) support image inputs and multiple providers, but documented CSV-of-images workflows were thin. A ~300-line custom runner plus SQLite is simpler for this. **[secondary]**

## 5. Is a Mac a valid proxy before running on the iPhone?

| Model class | Valid on Mac? | Caveats |
|---|---|---|
| **Cloud (Claude/GPT/Gemini)** | **Yes.** Same API, same model. | Send the identical canonical image bytes and prompt the phone app will send. The app's own resize/JPEG step must match the harness's. Network latency from the phone (cellular) differs; measure end-to-end latency on the phone separately. |
| **Small open VLM (MLX)** | **Yes for accuracy, if the checkpoint and quantization are identical.** No for latency or memory. | `mlx-vlm` (Python) and `mlx-swift-lm` (Swift) are different ports. Image preprocessing/resolution, chat template and quantization details can differ (e.g. a past issue where Python-quantized embeddings weren't loadable in Swift — [mlx-swift-examples #53](https://redirect.github.com/ml-explore/mlx-swift-examples/issues/53)). Use the exact 4-bit build you'd ship, not an 8-bit "nicer" Mac build. The phone may need a smaller input resolution to fit memory. That changes accuracy, so evaluate at the phone's resolution. Validate with greedy decoding on 10–20 images, Mac vs iPhone, and compare outputs. |
| **Apple FM on-device** | **Yes on macOS 27**, with care. | Apple says macOS 27 Foundation Models give access to "the same on-device model that powers Apple Intelligence", with multimodal prompts. macOS 27 shipped 2026-09-14 for M1 and newer Macs. — [Apple](https://developer.apple.com/macos/whats-new/); [MacRumors](https://www.macrumors.com/2026/09/10/macos-27-golden-gate-release-date/). **This Mac reports macOS 26.7.1 (build 25G241), which has no image input**; upgrade first. Things that can still differ: the model version is tied to the OS build, so match the 27.x point release on Mac and iPhone; context size is device-dependent (4096 vs 8192 "for newer devices"); and guardrail behaviour. Run a 15–20-meal confirmation subset on the iPhone and compare it to the Mac outputs with Bland–Altman. |
| **Apple PCC model** | Yes (`fm respond --model pcc`) | Daily per-user quota; plan repeats across days. Entitlement needed for app use; the CLI path may not need it (unverified). |

**Recommended sequence [inference]:**
1. Build the harness on the Mac.
2. Run cloud models + MLX (phone quant) + Apple FM (macOS 27) on the offline benchmark and the first ~30 personal meals.
3. Choose the finalists.
4. Run a phone confirmation subset for the on-device models: accuracy agreement, latency (cold/warm) and peak memory.
5. Finish the personal set (60–100 meals) on the finalists.

## Gaps / unverified
- Whether ACETADA item macros are served or consumed values; check the CSV.
- CalorieBench-80K: download location and whether it has macro labels. Food-R1 model size.
- `apple_fm_sdk` image-input API and sampling controls (only the CLI `--image` flag was confirmed).
- Whether `fm --model pcc` needs an entitlement on a developer Mac.
- No study compares 45° vs overhead phone photos for VLM macro estimation. The P1-vs-P2 comparison in this protocol would itself be new data.
- The sample-size table assumes SD_diff of 8–10 g. Replace it with the SD measured from the first ~30 meals.
