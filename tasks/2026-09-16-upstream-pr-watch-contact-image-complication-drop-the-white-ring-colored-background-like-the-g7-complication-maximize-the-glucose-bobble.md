+++
uid = "01a0a959-2553-711d-8a61-ee5b30d100a0"
key = "TRIO-054"
title = "Upstream PR: watch contact-image complication — drop the white ring, colored background like the G7 complication, maximize the Glucose Bobble"
status = "ready"
kind = "code"
source = "human"
created = 2026-09-16
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["watch", "contact-image", "complication", "upstream-pr"]

[[acceptance]]
id = "AC-1"
text = "Root cause of the white ring identified (stroke, border, or mask edge) for both the classic and Bobble renderers"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "Proposal / branch for: no ring, colored disc background, bobble scaled to the full canvas"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Before/after renders compared at watch complication size"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Upstream PR drafted (or a note on why it should stay fork-only)"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Side-by-side table: trigger, transport, latency, staleness handling, failure modes, telemetry — contact-image/Bobble path vs fork complications"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-6"
text = "Where the \"3m +0\" age in the Bobble is computed and how often it refreshes"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26
+++

## Intent

Operator request 2026-09-16, from two watch-face screenshots (Infograph face, Trio contact-image complication at the inner-bottom slot, Dexcom G7's own complication at the inner-right slot). Look into submitting an upstream PR to nightscout/Trio that changes the Apple Watch contact-image complication so it:

1. **Removes the white ring** around the contact image. In screenshot 1 the Trio complication (inner bottom, "67 →") is drawn with a thin white circular outline; the G7 complication beside it (inner right) has none.
2. **Uses a colored background like the Dexcom G7 watch complication** — the G7 slot fills the whole circle with a dark tinted disc (glucose-colored) behind the number and arrow, instead of black-with-outline.
3. **For the new "Glucose Bobble" option** (upstream PR https://github.com/nightscout/Trio/pull/1473, merged in the 0.8.4.78→.106 range as `Trio/Sources/Services/ContactImage/GlucoseBobbleContactView.swift`): remove the white ring around the edge of the circle, and work out how to make the bobble **as large as the available space allows** — in screenshot 2 (inner bottom, "67 / 3m +0") the bobble sits well inside a white outlined circle with visible dead space around it.

## Where to look

- `Trio/Sources/Services/ContactImage/` — `ContactImageManager`, `GlucoseBobbleContactView.swift` (new in #1473), the existing contact-image renderer(s) and their ring/border drawing.
- The image is a *contact photo* rendered by watchOS in a circular complication slot, so "maximize" means: fill the square canvas edge-to-edge with the disc, and any inset/padding/stroke the renderer adds shrinks the visible bobble. Check for an explicit stroke/border, an inset on the disc, and the canvas size vs the watch's circular crop.
- Compare against how the G7 app's own complication colors its disc (background = glucose range color, dark) — that is the look the operator wants.

## Notes carried over from acceptance criteria
## Also: compare the update pipelines (added 2026-09-16)

Operator addition: alongside the visual changes, **compare how the contact-image (Bobble) complication gets updated versus the fork's own complications** (patch 09 `watch-g7`: `Trio Watch Complication/TrioWatchComplication.swift`, `Trio Watch Shared/TrioComplicationDataStore.swift`, `ComplicationLogBuffer.swift`, and the watch-side refresh paths in `Trio Watch App Extension/`).

Questions to answer, side by side:

- **Trigger:** what event kicks off each refresh — new glucose on the phone (`ContactImageManager` rendering a new contact photo and writing it through Contacts) vs the fork's WidgetKit timeline reload from `TrioComplicationDataStore` (App Group) fed by the watch app / phone→watch transfer.
- **Transport & latency:** phone → iCloud/Contacts sync → watch contact cache → complication redraw (how long does that take, and is it throttled by iOS/watchOS?) vs App Group write → `WidgetCenter.reloadTimelines` (and its budget).
- **Freshness/staleness handling:** does the contact-image path ever show a stale value without indicating age? Screenshot 2 shows "3m +0" inside the Bobble — where is that age computed and when does it stop updating? The fork's complications carry a staleness indicator; note the difference.
- **Failure modes:** what happens to each when the phone is unreachable, when Contacts sync lags, when watchOS evicts the widget budget; and what telemetry each path emits (the fork's `ComplicationLogBuffer` / `WatchResidentTelemetry` vs whatever the contact path logs).
- **Recommendation:** whether any of the fork's pipeline behaviors (staleness display, refresh cadence, telemetry) should be proposed upstream for the contact-image path along with the visual PR, or kept fork-only.

## Root cause of the "white ring" on the Glucose Bobble contact image (2026-09-23)

Verified against `upstream/dev`. The ring is the **loop-status ring**, and on the Bobble style it is drawn without any way for the user to turn it off:

1. `ContactImageEntry.ring` defaults to `.none` (`ContactTrickEntry.swift:8`), options are only `.none` ("Hidden") and `.loop`.
2. `ContactPicture.getImage` draws it in an `if contact.ring != .none` block at line 47, **before** `switch contact.layout` at line 72, with **no `.bobble` exclusion**. The same block insets `rect` twice — by `outerGap = 0.03`, then by `ringWidth + ringGap` — and the `.bobble` branch then sizes the bobble from the shrunken `min(rect.width, rect.height)`. That inset is why the bobble cannot be full size.
3. `ringColor()`: `.loopGreen` ≤5 min since `lastLoopDate`, `.loopYellow` ≤10 min, `.loopRed` >10 min, `.loopGray` when `lastLoopDate` is nil (`lastLoopDate = lastDetermination?.timestamp`, `ContactImageManager.swift:232`).
4. **But the UI hides Ring Settings for the Bobble layout** (`ContactImageDetailView.swift:78`, `AddContactImageSheet.swift:113`: `if contactImageEntry.layout != .bobble { Section("Ring Settings") ... }`), and the in-app help states the Bobble style "replaces Display Values, Ring Settings, and Font Settings". The layout `.onChange` handler resets `top` but **never resets `ring`** (`ContactImageDetailView.swift:57-63`).

So a user who set Ring = Loop Status under a non-bobble layout and then switched to Glucose Bobble keeps a ring the UI no longer lets them change. Operator hit exactly this: ring visible on the watch face and in the in-app preview, no control anywhere in the Bobble options.

**This is an inconsistency between the UI/help and the renderer, not a design choice** — which changes the shape of the upstream PR. It is a bug fix, not a unilateral removal of a functional feature.

Two honest options for the PR (operator to choose):
- **(a) Honour the documented intent:** skip the ring block (and its insets) when `layout == .bobble`. Matches the help text and the hidden UI section. Silently drops the loop ring for anyone currently getting it.
- **(b) Restore the control:** keep the Ring Settings section visible for the Bobble layout so the loop ring stays available and switchable, and make the inset conditional so the bobble renders full-size when the ring is Hidden. Preserves the feature for users who want loop status; costs one more section in the Bobble settings.

Recommendation: **(b)**, plus the conditional inset — it preserves a functional feature (the operator explicitly did not want to remove loop status for other users) and still delivers the maximized bobble and ring-free look for anyone who sets Ring = Hidden. Either way the inset fix is needed, because today even `ring = .none` leaves... (verify: with `.none` the whole block is skipped, so no inset — confirm on device).

**Operator workaround available now (also confirms the diagnosis):** switch Layout away from Glucose Bobble (e.g. Default), set Ring → Hidden, switch back to Glucose Bobble. The white ring should disappear and the bobble should render larger. If it does, the diagnosis above is confirmed; if it does not, the ring comes from somewhere else and this section needs revisiting.


## CORRECTION (2026-09-23): the white ring is NOT the loop ring, and is not removable from the contact image

The previous section misidentified it. Operator screenshots settle it: with Layout = Default and Ring Type = Loop Status, the preview shows a **green** ring (the loop-status ring) *inside* a separate thin **white** circle, and the white one does not respond to Ring Width or Ring Gap. Two different rings.

Verified in code:

- **`ContactPicture` never draws a white outer circle.** Exhaustive grep of every drawing primitive in the file: the only `UIColor.white` stroke is at line 620, inside `drawGradientArc`, an `addArc(radius: 0)` degenerate end-cap used by the progress-bar ring styles (the commented-out iob/cob variants). The generated image has no white ring.
- **The white ring in the in-app preview is the settings UI's own border:** `ContactImageDetailView.swift:32-35` draws `Circle().stroke(lineWidth: 2)` colored `.white` in dark mode over the rendered image. Same pattern in `ContactImageRootView.swift:65` and `AddContactImageSheet.swift:67`. Pure preview decoration — it shows the circular crop boundary and is not part of the contact image.
- **The white ring on the watch face is watchOS system chrome** for a contact photo in the Contacts complication slot. Trio's image is transparent-background and contains no such ring, so nothing in Trio can remove it.

### Consequences for this task

1. **"Drop the white ring" is not achievable for the contact-image path.** No upstream PR can remove it, because Trio does not draw it. That part of this task's intent must be dropped or re-scoped.
2. What *is* in Trio's control on this path is **bobble size**: the `if contact.ring != .none` block applies `outerGap = 0.03` and then `ringWidth + ringGap` insets before `.bobble` sizes itself. With Ring = Hidden the whole block is skipped and no inset applies — so on the contact side "maximize the bobble" reduces largely to being able to set Ring = Hidden.
3. The **real, narrow upstream bug** that remains: the Bobble layout hides the Ring Settings section (`ContactImageDetailView.swift:78`) while `getImage` still honours `contact.ring` for that layout, and the layout `.onChange` never resets `ring`. A user who set Loop Status under another layout then switched to Bobble keeps a green ring with no control. Fix: either expose Ring Settings for Bobble, or reset `ring` on switching to it. Small, self-contained, defensible PR — and unrelated to the white ring.
4. The operator's desired ring-free look is therefore only reachable via a **native WidgetKit complication** (TRIO-063), which has no system contact border. That is now the primary justification for TRIO-063 rather than a stylistic preference.
