# Meal Photo Nutrition Autofill — Ideas

**Area:** Trio AI Features › Area 1
**Version:** v1.1
**Created:** 2026-03-22
**Last updated:** 2026-03-22 15:07 CET
**Status:** Pre-design — ideas and open questions

---

## Core Idea

When a user opens the AddCarbs screen in Trio, give them the option to take a photo of their meal. The image is sent to a GPT Vision model, which returns estimated carbs, fat, and protein. Those values pre-populate the form fields. The user reviews, adjusts if needed, and saves as normal. The image is never stored.

---

## Motivation

- Carb estimation by memory is a known source of loop noise, especially for mixed or restaurant meals.
- Most users have their phone out to initiate a bolus anyway — photo capture adds minimal extra steps.
- GPT-4o Vision produces usable macro estimates for a wide range of common foods.
- Even a rough estimate gives the loop a better starting point than a blank field or a repeated guess.
- Fat and protein estimates improve FPU conversion accuracy downstream, which matters for post-meal glucose control in Trio.

---

## User Flow (rough sketch)

1. User opens AddCarbs screen.
2. Taps "Analyze Meal Photo."
3. Confirmation dialog: "Take Photo" or "Choose from Library."
4. Image picker opens.
5. User captures or selects image.
6. App shows loading spinner ("Analyzing…").
7. GPT returns carbs/fat/protein.
8. Form fields pre-populated.
9. User reviews, edits if needed, taps Save.
10. Image discarded — not stored anywhere.

---

## Key Tensions

- **Accuracy vs. expectations.** Vision models estimate, not measure. Users who trust AI outputs implicitly and never edit them will get noisy data. The UI should reinforce that these are suggestions.
- **Latency.** API round-trips of 2–5 seconds are common. A spinner is mandatory; the question is whether fields remain editable during analysis or are locked.
- **Privacy.** The image is sent to OpenAI. This must be disclosed clearly before the first use. The feature must be strictly opt-in.
- **Cost.** Every analysis call costs tokens. Since users supply their own API key, cost is their concern — but the app should not make silent calls that surprise them.
- **No key = no feature.** The button should be hidden or show a configuration prompt when no API key is present, not silently fail.

---

## Open Questions

1. Should the button be hidden entirely until an API key is configured, or visible with a disabled state and a "configure in Settings" hint?
2. Should users be able to add a text annotation before sending — e.g., "large restaurant portion" or "this is a bowl of chili with sour cream"? This would improve accuracy for ambiguous photos.
3. Should the app show an image preview before sending, giving the user a chance to retake?
4. Should fat and protein be populated into their existing dedicated fields, or is there a data model issue to resolve first? **Resolved in design:** fat/protein fields exist as `Decimal` on `AddCarbs.StateModel`. AI-populated values auto-expand the FPU section if hidden.
5. Should estimation accuracy be tracked — i.e., does the app log when a user edits an AI-populated value before saving? This data would be useful for measuring real-world accuracy over time.
6. How should partial responses be handled — e.g., model returns carbs but omits fat and protein? **Resolved in design:** populate only fields present in the parsed response; others retain prior values. `MacroEstimate` uses optional `Decimal?` fields.
7. Should there be a disclaimer or confidence caveat shown alongside the pre-populated values?

---

## Settings Module Scope

A new `OpenAIConfig` settings module is needed regardless of Area 3, because Area 1 requires Keychain-backed API key storage with its own Settings UI. Area 3 (Nightscout side) manages its key via environment variable and does not share this module. The iOS `OpenAIConfig` module is Trio-only.

---

## Future Ideas (post-MVP)

- Text annotation field: user adds context before sending ("large portion", "restaurant serving").
- Image preview before sending, with option to retake.
- Confidence caveat or warning badge when the model response looks uncertain.
- Real-time camera mode (stream frames, update estimate live) — depends on model API capabilities.
- API key validation call (`GET /v1/models`) to surface invalid keys before first analysis attempt.
- Localization of all new strings.
- Feedback loop: track user edits to AI-populated values; surface aggregate accuracy stats in Settings.

---

## Related Areas

- **Area 2 (complete):** Fat and protein logged here flow to Nightscout as treatment data via the enriched device status payload. Field naming should be consistent with what Nightscout expects.
- **Area 3:** Post-meal BG response analysis in the weekly report benefits from accurate fat/protein logging. The more users adopt Area 1, the richer the Area 3 meal analysis becomes.

---

## Changelog

### v1.1 (2026-03-22 15:07 CET)
- Red team review: annotated resolved open questions (Q4 fat/protein fields, Q6 partial responses) with design decisions. Added `Last updated` timestamp.

### v1.0 (2026-03-22)
- Initial creation.
