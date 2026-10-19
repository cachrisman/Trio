# Accuracy evidence for AI photo-based meal macro estimation (carbs / protein / fat) and implications for T1D insulin dosing

Research date: 2026-10-13. Scope: peer-reviewed and preprint evidence 2023–2026 (plus foundational pre-2023 human/GoCARB baselines). Evidence tier is labeled on every study: **[PR]** = peer-reviewed journal/conference, **[PR-letter]** = peer-reviewed research letter (short, limited methods), **[Preprint]** = not peer reviewed, **[Vendor]** = company claim. Several full texts were paywalled/blocked (ScienceDirect, Diabetes Care, PMC CAPTCHA); where only an abstract was read, that is stated.

## Q1. How accurate are general-purpose VLMs (GPT-4o/5, Gemini, Claude) at estimating carbohydrate from a meal photo?

### Takeaway
On mixed/composite meals, image-only frontier VLMs typically land at roughly 6–18 g mean absolute error (MAE), ~13–35% MAPE, with only ~45–70% of estimates within ±10 g; on simple single foods (fruit, packaged items) they do much better (~90%+ within ±10 g). Accuracy improves sharply when the user adds a text description of ingredients/portions — the single largest lever reported in any study.

### Cited Findings
**Diabetes-specific, carb-focused studies (most decision-relevant)**
- **Soyer et al., Diabetes Res Clin Pract 2026 (vol 236, 113279) [PR, abstract only]** — 14 adults with T1D; 18 main meals + 4 snacks; models ChatGPT-5.2, Gemini-3 Pro, Claude Sonnet-4.5; two stages: image-only vs image + detailed description. Patients: MAE 8.31 g, MAPE 13.82%, "counting accuracy" (≤10 g error) 73.74%. Stage 1 (image only): Gemini lowest MAE 6.55 g / MAPE 12.54%; Claude highest counting accuracy 81.8%; other model/stage combos "comparable to patients". Stage 2 (image + description): Gemini MAE 2.14 g, MAPE 3.21%, 100% within 10 g, mean bias −1.05 g, outperformed patients (p<0.001). — [Europe PMC record / DOI 10.1016/j.diabres.2026.113279](https://www.sciencedirect.com/science/article/abs/pii/S0168822726001993)
- **Johansen et al., J Diabetes Sci Technol 2026 (e-pub 28 Feb 2026) [PR, abstract only]** — ChatGPT-4o; 60 fruits/vegetables + 60 composite meals, 240 images (with and without a size reference object); reference = manual carb count. Within ±10 g: fruit/veg 93.3% (95% with size reference); composite meals 46.7% (43.3% with size reference — the reference object did NOT help). Bland-Altman: without size reference, systematic bias with both over- and under-estimation; with reference, slight bias. MAE stated as a primary measure but not given in abstract. — [DOI 10.1177/19322968261424270](https://doi.org/10.1177/19322968261424270)
  - A citing paper reports the Johansen composite-meal MAE as 13.9–17.5 g. — [Lian et al., Front Nutr 2026](https://www.frontiersin.org/journals/nutrition/articles/10.3389/fnut.2026.1927840/full)
  - Same group published a follow-up letter "Augmented Food Image Analysis With Multimodal LLMs to Support Carbohydrate Counting in Diabetes" (JDST 2026;20(3):1048–1049) — no abstract/numbers retrieved. — [PubMed 41863834](https://pubmed.ncbi.nlm.nih.gov/41863834/)
- **Tecce et al., Diabetes Care 2025;48(8):e97–e98 [PR-letter; full text blocked, numbers via search snippet + citing paper]** — GPT-4o vs Gemini Advanced for T1D carb counting. GPT-4o MAPE fell with more context: 34.8% (minimal info) → 18.1% (moderate) → 13.7% (full ingredient details). GPT vs Gemini not significantly different under minimal data. — [Diabetes Care](https://diabetesjournals.org/care/article/48/8/e97/160531/AI-Powered-Carbohydrate-Counting-for-Type-1); 18.1%/13.7% figures corroborated by [Lian et al., Front Nutr 2026](https://www.frontiersin.org/journals/nutrition/articles/10.3389/fnut.2026.1927840/full)
- **Lian et al., Front Nutr 2026 (published 29 Sep 2026) [PR, full text read]** — Singapore; 150 real-world items (90 simple, 60 composite) from hawker centres, food courts, restaurants, homes; reference = dietitian-weighed values (mean 35.2 ± 16.3 g carbs). ChatGPT-5 (web UI, single response, prompt "Please estimate the amount of carbohydrate."): MAE 8.7 ± 7.4 g (median 6.0 g), MAPE 32.9% (median 22.1%), 69.3% within ±10 g, Bland-Altman bias **+2.79 g (overestimation; significant vs zero, p=0.002)**. Comparator NutriDish (RAG + fine-tuned open-weight VLM + local nutrition DB): MAE 5.9 ± 5.3 g, MAPE 22.1%, 80.7% within ±10 g, bias +0.80 g (n.s.). NutriDish simple vs composite: MAE 4.1 vs 8.6 g; within ±10 g 91.1% vs 65.0%. Note abstract vs results p-value inconsistency (0.016 vs 0.017). — [Front Nutr](https://www.frontiersin.org/journals/nutrition/articles/10.3389/fnut.2026.1927840/full)
- **Joubert et al., Diabetes Obes Metab 2026;28:2105–2112 (online Dec 2025) [PR, abstract only]** — independent bicentric study; 246 hospital meals photographed by medical students as mock patients. MAE: GluciCheck 13.0 ± 9.9 g; EkiYou 14.2 ± 12.5 g; DiabHealth 13.9 ± 9.9 g; Gluroo 20.6 ± 14.6 g; **ChatGPT-5 18.0 ± 16.0 g**. Within ±20 g: GluciCheck 77%, EkiYou 67%, DiabHealth 80%, Gluroo 50%, ChatGPT-5 73%. Only Gluroo significantly worse than GluciCheck. ChatGPT-5 and DiabHealth "minimal bias and no proportional error"; Spearman ρ ≈0.50 for ChatGPT-5. — [DOI 10.1111/dom.70396](https://doi.org/10.1111/dom.70396)

**General nutrition VLM studies (not diabetes-specific)**
- **Mu, Sun, He, ACM BCB 2025 [PR conference]** — 7 LMMs (full + lightweight GPT, Gemini, Llama) on Nutrition5k and a phone-collected DonateAndLearn set (78 test cases). Carb MAPE for Gemini 2.5 Flash 56.6% image-only → 39.5% with predicted weight; with ground-truth weight, 20.2% (Gemini 2.5 Flash) and 26.8% (GPT-4.1). GPT-4.1 best of three LMMs in all four nutrient categories, carbs ~33.01% MAPE. — [PubMed 42502812](https://pubmed.ncbi.nlm.nih.gov/42502812/); [PMC13401436](https://pmc.ncbi.nlm.nih.gov/articles/PMC13401436/)
- **"Performance Evaluation of 3 LLMs for Nutritional Content Estimation from Food Images", Current Developments in Nutrition 2025 [PR, via search snippet]** — ChatGPT and Claude similar (MAPE 36.3% / 37.3% for weight, ~35.8% for energy); Gemini much worse (MAPE 64.2%–109.9% across nutrients). Model versions not captured. — [PMC12513282](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12513282/)
- **Lo et al., IEEE JBHI 2024;28:7577–7587 (arXiv 2312.08592) [PR]** — GPT-4V on wearable-camera semi-free-living data; food detection up to 87.5% accuracy without fine-tuning (preprint figure); uses surrounding objects as scale references; prompting with cuisine (e.g., "African cuisine") shifted recognition to regional dishes (banku, ugali). A secondary summary reports GPT-4V portion MAE comparable to dietitians (46.3 g vs 48.5 g food weight — this is food mass, not carbs; not verified against full text). — [arXiv 2312.08592](https://arxiv.org/pdf/2312.08592); dietitian-comparison figure via [search summary of DietAI24 citing context](https://www.nature.com/articles/s43856-025-01159-0)
- **Chen et al., Am J Clin Nutr 2025;122(6):1836–1849 [PR, abstract]** — Taiwan; 714 images from 57 young adults over 171 days vs weighed food records. Custom "Diabot-GPT-4o" vs plain GPT-4o: food recognition 74% vs 59%. Ranges across configurations: carbs ±15–20%, CV 15%; fat ±10–22%, CV 24%; protein ±10–>20.2%, CV 18%. Conclusion: accuracy "depends on clear images for food visibility." — [DOI 10.1016/j.ajcnut.2025.10.013](https://doi.org/10.1016/j.ajcnut.2025.10.013)

### Inferences
- A reasonable planning number for **image-only, frontier VLM, composite meal** carb estimation is **MAE ~9–18 g, ~45–70% within ±10 g**; for simple single items ~4–6 g MAE and ~90% within ±10 g. The best image-only result (Gemini-3 Pro, 6.55 g, Soyer 2026) comes from a tiny sample (22 meals) in a single Turkish centre.
- Model rank-ordering is unstable across studies (Gemini worst in one 2025 study, best in Soyer 2026), consistent with strong dependence on model version, prompt, and dataset. Do not hard-code a vendor choice on one paper.
- The direction of bias is not consistent across studies: ChatGPT-5 overestimated (+2.8 g) in Singapore; Gemini-3 slightly underestimated (−1.05 g) with descriptions; Johansen saw both directions. Overestimation of carbs → overbolus → hypoglycemia risk, which is the more acute safety concern.
- Because "image + user text description" collapses error (Soyer: 6.55 → 2.14 g; Tecce: 34.8% → 13.7% MAPE), a Trio design that prompts for a short description/portion hint is better supported by evidence than photo-only.

### Gaps
- No study reported full per-meal-type breakdown for VLMs on sauces, beverages, desserts/hidden sugars, or restaurant vs home meals with numbers; only "simple vs composite" splits exist.
- No Claude-model result beyond Soyer 2026 (Sonnet-4.5: highest within-10 g rate, MAE not in abstract) and the 2025 three-LLM study.
- Tecce 2025 sample size and MAE in grams not retrieved (paywalled letter).
- No study with an on-device/small VLM (e.g., Apple on-device model, Qwen2-VL-7B) reporting carb MAE in grams for diabetes meals; the bioRxiv ten-model benchmark (below) includes Qwen2-VL-7B but carb-specific results weren't in the abstract.

## Q2. Is protein and fat estimation from photos worse than carbohydrate estimation?

### Takeaway
In relative (%) terms, fat is consistently the hardest macronutrient to estimate from images (oil, dressing, absorbed cooking fat are invisible); protein is intermediate. In absolute grams, carb errors are often the largest simply because carb quantities are larger. Very few diabetes-specific studies validate fat/protein at all.

### Cited Findings
- Chen et al. 2025 (AJCN): coefficient of variation fat 24% vs protein 18% vs carbs 15%; fat accuracy band ±10–22%. — [DOI 10.1016/j.ajcnut.2025.10.013](https://doi.org/10.1016/j.ajcnut.2025.10.013)
- Open-KNEAD preprint (arXiv 2607.12911, 2026) Nutrition5k direct-prompting baseline: percentage error protein 44.5%, fat 65.7%, carbs 61.6%; gram MAE carbs 11.7 g, fat 9.0 g, protein 7.1 g. [Preprint; figures from search summary, not verified in full text] — [arXiv 2607.12911](https://arxiv.org/pdf/2607.12911)
- Wang et al., Current Research in Food Science 2026 (VLMs on Nutrition5k): supplying correct ingredient categories "primarily benefits fat and protein estimation"; large nutrient errors persist even with correct ingredients; composite/visually ambiguous dishes remain difficult. [PR, abstract] — [ScienceDirect S266592712600105X](https://www.sciencedirect.com/science/article/pii/S266592712600105X)
- Nakagawa & Yamamoto, Nutrients 2026: notes fat largely comes from seasoning, dressing and absorbed cooking oil and is "not readily legible from a single image". — [Nutrients 18(17):2892](https://www.mdpi.com/2072-6643/18/17/2892)
- Lian et al. 2026: NutriDish also outputs protein/fat/energy, but the authors validated carbohydrate only. — [Front Nutr](https://www.frontiersin.org/journals/nutrition/articles/10.3389/fnut.2026.1927840/full)
- Wang, Lane, Waki (JMIR Diabetes 2026): within-image (run-to-run) instability is likely greatest for nutrients with no clear visual cue (salt, fiber); carbs and protein had comparatively lower relative variability than other nutrients except energy. — [JMIR Diabetes 11:e102715 / PMC13544413](https://pmc.ncbi.nlm.nih.gov/articles/PMC13544413/)

### Inferences
- For Trio's fat-protein unit (FPU) conversion, fat errors of ±50–65% relative are plausible from photo-only estimation. Because FPU converts fat (9 kcal/g) and protein (4 kcal/g) into extended "carb equivalents", a 15 g fat overestimate alone adds ~135 kcal → ~1.35 FPU-equivalent extended carbs under the common 100 kcal = 10 g convention (verify Trio's actual factor/delay settings). That is a delayed, harder-to-notice overbolus source.
- Safer defaults: show fat/protein as lower-confidence, require explicit confirmation separately from carbs, or default FPU pre-fill off.

### Gaps
- No diabetes-population study found that validated VLM fat/protein estimates against weighed references and examined glycemic consequences.
- No study found quantifying the dosing impact of FPU errors specifically.

## Q3. How does AI compare with dietitians and with people with T1D counting by eye? What error thresholds matter?

### Takeaway
People with T1D err by roughly 8–28 g per meal (≈14–71% depending on setting), usually underestimating; dietitians estimating from photos err ~15 g. Purpose-built systems (GoCARB, SNAQ) and frontier VLMs on mixed meals are in the same ballpark or modestly better — not clearly better than a competent counter. Clinical evidence says errors ≥20 g materially change postprandial glucose, and pediatric guidance targets ±10 g.

### Cited Findings
**Human baseline**
- Brazeau et al., Diabetes Res Clin Pract 2013;99(1):19–23 — 50 adults with T1D, 448 meals from 72-h records vs dietitian values: mean error 15.4 ± 7.8 g/meal (20.9 ± 9.7%); 63% of meals underestimated; larger errors predicted higher glycemic variability. [secondary summary] — [ResearchGate record](https://www.researchgate.net/publication/233403794_Carbohydrate_couting_accuracy_and_blood_glucose_variability_in_adults_with_type_1_diabetes)
- Smart et al., Diabet Med 2010;27:348–353 — 102 children + 110 caregivers, 17 standardized meals: 73% of estimates within 10–15 g; gram error grew with meal size. — [Wiley](https://onlinelibrary.wiley.com/doi/10.1111/j.1464-5491.2010.02945.x)
- Smart et al., Diabet Med 2009;26:279–285 — 10 g variation around a 60 g meal produced no difference in BG or AUC over 2.5 h. — [Wiley](https://onlinelibrary.wiley.com/doi/10.1111/j.1464-5491.2009.02669.x)
- Smart et al., Diabet Med 2012;29(7):e21–e24 — dosing for 60 g: 40 g meal → significantly more hypoglycaemia (P=0.003; ~1 in 3 chance between 120–180 min); 80 g meal → significantly higher glucose 150–180 min (P<0.01) and more hyperglycaemia (P<0.001). Conclusion: estimates should be within 10 g. — [Wiley](https://onlinelibrary.wiley.com/doi/10.1111/j.1464-5491.2012.03595.x)
- Deeb et al., JDST 2017 — children on pumps; 55% of accurately counted meals had in-target postprandial glucose; accurate counting an important determinant of postprandial glycemia. — [DOI 10.1177/1932296816679850](https://doi.org/10.1177/1932296816679850)
- Meade & Rushton, Clinical Diabetes 2016;34(3):142–147 — 61 adults (T1D/T2D, MDI or CSII) tested on food items; scoring windows ±3–5 g. Key quantitative findings not verified (full text not read). — [Clinical Diabetes](https://diabetesjournals.org/clinical/article/34/3/142/31348/Accuracy-of-Carbohydrate-Counting-in-Adults)
- Roversi et al., JDST 2022 — in silico trial quantifying the impact of carb counting error on glycemic control in open-loop T1D (numbers not extracted). — [JDST](https://journals.sagepub.com/doi/full/10.1177/19322968211012392)
- Review: "Assessing Carbohydrate Counting Accuracy: Current Limitations and Future Directions", Nutrients 2024;16(14):2183. — [MDPI](https://www.mdpi.com/2072-6643/16/14/2183)

**Head-to-head AI vs humans**
- Soyer 2026: patients 8.31 g MAE / 73.7% within 10 g vs image-only VLMs "comparable"; only image + description Gemini beat patients. — [DRCP 2026](https://www.sciencedirect.com/science/article/abs/pii/S0168822726001993)
- Rhyner et al., JMIR 2016;18(5):e101 (GoCARB) — 19 adults with T1D, 6 restaurant-style meals each: participants MAE 27.89 ± 38.20 g vs GoCARB 12.28 ± 9.56 g (P=.001). Automatic segmentation succeeded on 75.4% of meals; 85.1% of items recognized. — [JMIR](https://jmir.org/2016/5/e101)
- Vasiloglou et al., Nutrients 2018;10:741 (GoCARB vs 6 dietitians, 54 meals): MAE 14.8 ± 9.73 g vs 14.9 ± 10.12 g (p=0.93); errors grew with meal size for both; GoCARB struggled with rice, pasta, potatoes, mash. — [PMC6024682](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6024682/)
- Baumgartner et al., JDST 2025;19(6):1570–1577 (SNAQ, Calorie Mama vs 53 people with T1D, 26 cooked meals): participants 21 ± 21.5 g (71%); Calorie Mama 24 ± 36.5 g (81.2%); SNAQ 13.1 ± 11.3 g (44.3%). Abstract states SNAQ "outperformed ... (both P > .05)" — i.e., not statistically significant as written; internally inconsistent wording. — [DOI 10.1177/19322968241264744](https://doi.org/10.1177/19322968241264744); [ETH record](https://www.research-collection.ethz.ch/items/6a84cd55-fa85-4acc-8d7d-21c86c0d436b)

**Does accurate counting even matter under AID?**
- Schumacher et al., Diabetes Technol Ther 2026 (pilot RCT, n=12, Lyumjev AID): TIR 75.4% (carb counting) vs 72.9% (qualitative meal-size estimate), P=0.191; vs 71.0% fully closed-loop, P=0.192. — [DOI 10.1177/15209156261456440](https://doi.org/10.1177/15209156261456440)
- Blervaque et al., DT&T 2025 — retrospective real-life comparison of simplified meal-size estimation vs precise counting with DBLG1 HCL (numbers not extracted). — [DOI 10.1177/15209156251362700](https://doi.org/10.1177/15209156251362700)
- Everett et al., Endocr Pract 2026 (survey n=903 adults T1D): 54% carb count, 39% estimate by experience, 51% never used apps. — [DOI 10.1016/j.eprac.2026.09.011](https://doi.org/10.1016/j.eprac.2026.09.011)

### Inferences
- The clinically meaningful threshold for a single meal is ~±10 g (pediatric guidance, Smart 2012) and clearly ±20 g. Current image-only VLMs miss ±10 g on composite meals 30–55% of the time — roughly the same failure rate as average patients. An AI pre-fill is therefore best framed as "comparable to an unaided guess, better than a poor guesser", not as a precision tool.
- The largest benefit is likely for users with large/inconsistent errors (Baumgartner's own conclusion; Rhyner's 27.9 g patient MAE). Users who already count well (Soyer patients 8.3 g) gain little from image-only estimation.
- AID (including Trio's oref-based SMB/UAM) partially absorbs moderate carb errors (Schumacher pilot), which lowers the stakes of ~10 g errors but does not protect against large overestimates (hypo risk from front-loaded bolus).

### Gaps
- No study found that measured glycemic outcomes (TIR, hypos) when AID users dosed from VLM-generated carb estimates.
- Meade & Rushton key percentages unverified.

## Q4. Dedicated diabetes food-photo apps: validated accuracy and regulatory status

### Takeaway
Only GoCARB (academic) and SNAQ have meaningful peer-reviewed validation (≈12–15 g MAE). Most consumer apps (Cal AI, MyFitnessPal Meal Scan, Calorie Mama, Undermyfork, Diabetes:M, Carbs & Cals) have no or poor published photo-carb validation; Calorie Mama was worse than patients. No consumer photo-carb app was found with FDA clearance; SNAQ explicitly disclaims medical-device status and insulin-dosing use.

### Cited Findings
- GoCARB: see Q3 (Rhyner 2016 12.28 g; Vasiloglou 2018 14.8 g). Uses a reference card, plate detection, segmentation, 3D reconstruction, USDA DB. — [JMIR 2016](https://jmir.org/2016/5/e101); [PMC6024682](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6024682/)
- SNAQ: Baumgartner 2025 13.1 g MAE (44.3%) — [JDST 2025](https://doi.org/10.1177/19322968241264744). SUMMIT1 trial (NCT05671679), ~44 adults with T1D, SNAQ vs traditional counting, listed completed; results not retrieved. — [ClinicalTrials.gov](https://clinicaltrials.gov/study/NCT05671679)
- SNAQ [Vendor] claims users "reduced carb counting errors by 38%" vs manual counting; its site and App Store listing state it is a health and wellness app, not a medical device, not intended for insulin dosing. — [snaq.ai](https://www.snaq.ai/diabetes-food-tracker); [App Store](https://apps.apple.com/us/app/snaq-diabetes-food-tracker/id1465916014)
- CarbVis (Qarbs app), merged into SNAQ AG in 2023, reported a class I MDD certification and a submitted class II MDR application; this attaches to CarbVis's product, not clearly the SNAQ consumer app. [Vendor/press] — [Diabetes Center Berne](https://www.dcberne.com/en/snaq-and-carbvis-join-forces/)
- Calorie Mama: 24 ± 36.5 g MAE (81.2%), worse than patients (21 g) in Baumgartner 2025. — [JDST 2025](https://doi.org/10.1177/19322968241264744)
- French apps (GluciCheck 13.0 g, EkiYou 14.2 g, DiabHealth 13.9 g) and Gluroo 20.6 g vs ChatGPT-5 18.0 g (Joubert 2026). — [DOM 2026](https://doi.org/10.1111/dom.70396)
- Image-recognition carb app pilot RCT in youth with T1D (JMIR mHealth 2020) exists; results not extracted. — [PMC7657721](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7657721/)
- Tiabete (Brazil) AI carb-counting efficacy/safety trial in children and adults with T1D registered (NCT07150052); no results. — [ClinicalTrials.gov](https://clinicaltrials.gov/study/NCT07150052)
- Independent user review (Diabettech) reported SNAQ struggled with food identification and portion sizes. [blog, n=1] — [Diabettech](https://www.diabettech.com/tag/carb-counting/)

### Inferences
- The best dedicated apps (~12–14 g MAE) are not clearly better than frontier general VLMs (~9–18 g) in comparable mixed-meal settings; the Lian 2026 NutriDish result (5.9 g) suggests RAG + local food database grounding is the most promising architecture.

### Gaps
- No peer-reviewed accuracy data found for Cal AI, MyFitnessPal Meal Scan, Undermyfork (CGM-correlation app, not an estimator), Diabetes:M, Carbs & Cals (photo atlas, not AI), or DiaCARE.
- No confirmed CE/FDA clearance found for any photo-based carb estimator; EUDAMED not checked.

## Q5. Benchmarks (Nutrition5k, NutriBench, others): frontier vs small models

### Takeaway
Nutrition5k (Google; overhead cafeteria photos with weighed ground truth) is the de facto image benchmark; frontier "Flash"-class models now lead, and an open 7B model and commercial API lag. NutriBench is text-only (meal descriptions → carbs), useful for the "user description" path.

### Cited Findings
- Sterling et al., bioRxiv 2026.07.26.740845 (posted 29 Jul 2026) [Preprint, abstract only] — 10 approaches on Nutrition5k (3,229 images): Gemini 2.0/2.5/3.0 Flash, 3.1 Flash Lite; GPT-4o, GPT-4o-mini, GPT-5 Mini; Claude Haiku 4.5; Qwen2-VL-7B; FatSecret API. Best calories: Gemini 3.0 Flash (CCC 0.767, MAE 80.7 kcal). Gemini 3.1 Flash Lite CCC 0.754 at $0.59/1K images; Gemini 2.0 Flash CCC 0.742 at $0.10/1K. Human review found systematic omissions in Nutrition5k labels (ingredient-overlap for Gemini 2.0 Flash 0.62 → ~0.82 after correction). Per-macro and small-model numbers not in abstract. — [bioRxiv](https://www.biorxiv.org/content/10.64898/2026.07.26.740845v1)
- Mu et al., ACM BCB 2025 — 7 LMMs incl. lightweight variants; GPT-4.1 best; predicted/actual weight dramatically improves carb MAPE (Gemini 2.5 Flash 56.6% → 39.5% → 20.2%). — [PubMed 42502812](https://pubmed.ncbi.nlm.nih.gov/42502812/)
- NutriBench (arXiv 2407.12843) — text meal descriptions; carb MAE ~10–20 g for base/fine-tuned LLMs (via search summary). — [arXiv](https://arxiv.org/html/2407.12843v5)
- DietAI24 (Yan et al., Communications Medicine 2025) — MLLM + RAG over food composition DB (ASA24, Nutrition5k): 63% MAE reduction for weight and four key nutrients vs existing methods on mixed dishes (p<0.05). — [Nature Comms Med](https://www.nature.com/articles/s43856-025-01159-0)
- Benchmark "enriched with contextual metadata" (arXiv 2507.07048, 2025) — adding metadata (e.g., location/time/meal context) to LMM prompts; numbers not extracted. — [arXiv](https://arxiv.org/pdf/2507.07048)
- Velombe et al., Nutrients 2026 — hybrid CNN + MLLM: 94.91% classification accuracy across 40 categories; portion MAE 12.27 g (food mass). — [DOI 10.3390/nu18132205](https://doi.org/10.3390/nu18132205)

### Inferences
- Portion/weight is the dominant error source: supplying weight roughly halves carb MAPE. Anything that gets the true mass (user input, scale, depth) matters more than model choice.
- Nutrition5k is cafeteria food photographed overhead under controlled conditions with noisy labels; it likely overstates real-world phone-photo accuracy.

### Gaps
- MM-Food-100K results not found in this pass.
- No published per-macro head-to-head of on-device small VLMs vs frontier cloud models on a diabetes-relevant dataset.

## Q6. Failure modes and mitigations (scale ambiguity, hidden ingredients, variance, prompt sensitivity; do reference objects / angles / depth / text hints help?)

### Takeaway
The main failure modes are portion/scale ambiguity, composite dishes, invisible fat/sugar, and non-trivial run-to-run and photo-to-photo variance. User-supplied text (ingredients/portions) and known weight help a lot; a physical size reference object did not help GPT-4o in the one diabetes study that tested it; prompt persona can systematically bias quantities.

### Cited Findings
- Scale/composite: GPT-4o composite meals 43–47% within ±10 g vs 93–95% for fruit/veg; size reference did not improve composite meals (46.7% → 43.3%). — [Johansen JDST 2026](https://doi.org/10.1177/19322968261424270)
- Reference objects in NutriDish: plate 82.1% within ±10 g; coin 57.1% (MAE 9.3 g, MAPE 48.1%); nutrition label 90.9% (authors caution label values weren't visible, so likely training familiarity). — [Front Nutr 2026](https://www.frontiersin.org/journals/nutrition/articles/10.3389/fnut.2026.1927840/full)
- GoCARB required a reference card and still failed automatic segmentation on ~25% of meals. — [JMIR 2016](https://jmir.org/2016/5/e101)
- Text description: Soyer image-only 6.55 g → image + description 2.14 g (Gemini); Tecce 34.8% → 13.7% MAPE. — [DRCP 2026](https://www.sciencedirect.com/science/article/abs/pii/S0168822726001993); [Diabetes Care 2025](https://diabetesjournals.org/care/article/48/8/e97/160531/AI-Powered-Carbohydrate-Counting-for-Type-1)
- Known weight: carb MAPE 56.6% → 20.2% (Gemini 2.5 Flash). — [ACM BCB 2025](https://pubmed.ncbi.nlm.nih.gov/42502812/)
- Run-to-run and presentation variance: Wang, Lane, Waki (JMIR Diabetes 2026) — 20 image pairs of same meal (10 differing viewpoint, 10 differing arrangement), 60 independent requests per image, fixed prompt and "deterministic parameter settings"; GPT-4o and GPT-5.1. Variability "nonnegligible" even with deterministic settings; GPT-4o more sensitive to arrangement than viewpoint; GPT-5.1 more variable overall, driven by between-image variability. Suggested mitigations: multiple photos and repeated requests (cost/latency trade-off). Precision only; no accuracy vs truth. — [PMC13544413](https://pmc.ncbi.nlm.nih.gov/articles/PMC13544413/)
- Prompt sensitivity: a "Japanese-dietitian" persona prompt lowered predicted energy in all 6 VLMs across 2,159 images (persona effect p<10^-94), improving small-portion error by up to ~20 MedAPE points but acting as a systematic downward bias. — [Nutrients 2026](https://www.mdpi.com/2072-6643/18/17/2892)
- Cuisine prompting shifts recognition (GPT-4V: banku, ugali); scale from surrounding objects. — [Lo et al. arXiv](https://arxiv.org/pdf/2312.08592)
- Hidden ingredients / preparation: education-sector commentary that apps misidentify look-alike foods and miss preparation/hidden ingredients; advises not to use AI tools to calculate insulin doses. [non-peer-reviewed] — [Diabetes Education Services](https://diabetesed.net/carbohydrate-counting-in-the-ai-era/)
- Proportional bias: NutriDish slope −0.09 (p=0.034) — overestimates small, underestimates large meals; errors grow with meal size for GoCARB and dietitians. — [Front Nutr 2026](https://www.frontiersin.org/journals/nutrition/articles/10.3389/fnut.2026.1927840/full); [Vasiloglou 2018](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6024682/)
- Image clarity: accuracy "depends on clear images for food visibility". — [Chen AJCN 2025](https://doi.org/10.1016/j.ajcnut.2025.10.013)
- Depth: DPF-Nutrition (arXiv 2310.11702) fuses predicted depth for nutrition estimation (numbers not extracted). — [arXiv](https://arxiv.org/pdf/2310.11702)
- Before/after images (DietDelta, arXiv 2604.06352) and agentic interactive estimation (CVPR 2026 workshop) are emerging approaches (numbers not extracted). — [arXiv DietDelta](https://arxiv.org/pdf/2604.06352); [CVPRW 2026](https://openaccess.thecvf.com/content/CVPR2026W/MTF/papers/Bhatambarekar_An_Agentic_Vision-Language_Pipeline_for_Interactive_Nutritional_Estimation_from_Food_CVPRW_2026_paper.pdf)

### Inferences
- Design implications for Trio: (1) ask for a short text description/portion hint; (2) never auto-commit — show a range or confidence and the item breakdown; (3) consider multiple samples/aggregation (median of N) and flag high disagreement as low confidence; (4) pin model version and prompt, because both shift bias; (5) cap or warn on large estimates and treat drinks/sauces/desserts as explicit "confirm" items; (6) LiDAR/depth is plausible but no diabetes-specific evidence that it improves carb MAE was found.
- Hallucinated confidence: none of the studies reported calibrated uncertainty; VLMs give point estimates without reliable error bars, so any displayed confidence must come from Trio-side heuristics (sample spread), not the model's self-report.

### Gaps
- No quantitative evidence found specifically for beverages, sauces or hidden sugars, adversarial/non-food inputs, or LiDAR/multi-angle gains on carb MAE.
- No study measured whether showing users an AI pre-fill anchors them (automation bias) and reduces their correction of errors.

## Q7. Regulatory and clinical-organization framing

### Takeaway
Bolus calculators are regulated device functions (FDA 510(k) precedents); an AI carb estimate that directly feeds a bolus calculator is very likely part of a device function under FDA and EU MDR, and patient-facing image-analysing software cannot use the FDA non-device CDS carve-out. No ADA/ISPAD/Diabetes UK/Breakthrough T1D guidance specific to AI photo carb counting was found; ISPAD 2022 treats apps as learning aids.

### Cited Findings
- FDA cleared bolus-calculator software: BlueStar CGM insulin dose calculator (K222888) calculates bolus from carbs, iCGM glucose/trend, activity, optional IOB; Omnipod 5 SmartBolus Calculator (K203772) used as predicate. — [FDA K222888 PDF](https://www.accessdata.fda.gov/cdrh_docs/pdf22/K222888.pdf)
- FDA Clinical Decision Support Software final guidance (2026 revision) exists at the FDA media URL; I could not parse the PDF. A search-indexed FDA webinar transcript reportedly states the revised guidance was issued 6 Jan 2026 (re-issued 29 Jan 2026) and uses an example of software computing insulin doses from carb intake, pre-meal glucose and activity as a device function — transcript URL not retrieved; treat as unverified. Search-result title for the PDF says "Final Guidance March 11, 2026" — date conflict unresolved. — [FDA CDS guidance PDF](https://www.fda.gov/media/191560/download)
- SNAQ markets itself as wellness, not a medical device, not for insulin dosing — the typical way consumer photo-carb apps avoid device status. — [App Store](https://apps.apple.com/us/app/snaq-diabetes-food-tracker/id1465916014)
- 2013 FDA mobile medical apps stance: apps recommending calorie/carb intake for tracking were outside enforcement focus — does not cover insulin dosing. — [Nextgov 2013](https://www.nextgov.com/modernization/2013/09/fda-will-regulate-some-mobile-medical-apps-devices/70760/)
- ISPAD 2022 Nutrition chapter: carb counting resources including apps and digital games are "useful tools to learn and estimate" — educational framing; no AI-specific guidance found in ISPAD 2024 chapters retrieved. — [ISPAD 2022 Ch.10](https://www.digibete.org/wp-content/uploads/2023/05/ISPAD-Ch_10_Nutrition.pdf)

### Inferences
- The statutory non-device CDS criteria (FD&C Act §520(o)(1)(E)) require that software not acquire/process/analyze a medical image or signal and be intended for health-care professionals; a patient-facing photo analyser feeding a dose calculator fails these on their face (criteria recalled from prior knowledge; verify against the guidance text).
- Trio is open-source, DIY-built, and not distributed as a commercial device; regulatory exposure differs from a commercial app, but the "user must confirm; tool is an estimate; not a dosing recommendation" framing used by SNAQ is the norm, and patient-safety design (confirmation, caps, provenance logging) matters regardless.

### Gaps
- No ADA Standards of Care, Diabetes UK, or Breakthrough T1D statement on AI photo carb counting found in this pass (not exhaustively searched).
- EU MDR Rule 11 classification of a carb estimator feeding a dosing function not verified with a primary source.
- Exact 2026 CDS guidance text, date and bolus example unverified.
