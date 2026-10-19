+++
uid = "01a0e315-4189-776b-8289-a7450ba9a091"
key = "TRIO-070"
title = "Glucose Bobble circular complication: text and trend arrow are too small to read on-wrist"
status = "ready"
kind = "code"
source = "human"
created = 2026-09-27
updated = 2026-10-09
touched = 2026-10-09
owner = "me"
tags = ["watch", "complication", "patch-04", "legibility"]
files = ["Trio/Sources/Services/ContactImage/GlucoseBobbleContactView.swift", "Trio Watch Complication/GlucoseBobbleComplication.swift", "Trio/Sources/Models/GlucoseBobbleComplicationSettings.swift", "Trio/Sources/Modules/WatchConfig/View/GlucoseBobbleComplicationSettingsView.swift"]

[[acceptance]]
id = "AC-1"
text = "accessoryCircular secondary line (delta + recency) renders at >= 14 px cap height on a 52 pt slot -- parity with the accessoryCorner complication's secondary line"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-27

[[acceptance]]
id = "AC-2"
text = "accessoryCircular primary glucose number renders at >= 26 px cap height on a 52 pt slot -- parity with or better than the Dexcom circular complication"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-27

[[acceptance]]
id = "AC-3"
text = "Trend arrow height is >= 0.6x the glucose digits' cap height (Dexcom's ratio is ~0.77; current Trio is 0.30) -- on a 52 pt slot that is a visible arrow of ~18-22 px, up from 7 px"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-27

[[acceptance]]
id = "AC-4"
text = ".outsideRing placement (phone contact image + HUD bobble) is unchanged: Layout.nativeSize and the outsideRing branch of every TrendArrowPlacement property keep their current values"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-27

[[acceptance]]
id = "AC-5"
text = "Worst-case strings (mmol/L glucose '12.8', secondary '59m -0.6') still render on one line each without falling below minimumScaleFactor"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-27

[[acceptance]]
id = "AC-6"
text = "patches 03 and 04 regenerated via mid-stack-update.sh; patch-test.sh and patch-audit.sh pass"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-27

[[acceptance]]
id = "AC-7"
text = "On-wrist screenshot confirms the text and arrow are legible at a glance"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-09-27

[[acceptance]]
id = "AC-8"
text = "Phone settings preview uses the live glucose colour instead of the hardcoded Color.green in sampleGlucoseColor and the glucoseTint branch"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-27

[[acceptance]]
id = "AC-9"
text = "Trend arrow is sized without changing Triangle.swift's path (scaleEffect on a fixed 30x30 frame, or a placement-specific shape) so CurrentGlucoseView and the .outsideRing contact image are unaffected"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-27

[[acceptance]]
id = "AC-10"
text = "Phone settings expose font size, secondary font size, font weight and ring width, ported from ContactImageEntry's enums, with at least one FontSize case above 'large'"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-27
+++

## Intent

Follow-up to TRIO-063 (shipped in build 230, TRIO-069). Operator reports from an on-wrist screenshot (Apple Watch Ultra, 422x514 px face capture, 2026-09-27) that the complication's text is too small and the trend arrow is too small to see. Operator explicitly states that the arrow overlapping the text is acceptable -- the anti-overlap tuning done in b471e2292 traded away more legibility than it bought.

Measurements below are from that screenshot; the face capture is 2x, so 2 px = 1 pt.

## Measured sizes (screenshot, 2026-09-27, Apple Watch Ultra, 422x514 px = 211x257 pt @2x)

All three circular slots on the face measure **102 px = 51 pt** outer diameter (Trio bobble, the date subdial, and the Dexcom subdial all span exactly x=160..261 / x=254..355). So `accessoryCircular` on this watch is ~52 pt, and `GlucoseBobbleContactView`'s 256-unit canvas is scaled by **0.406 px per native unit** (0.203 pt per native unit).

| Element | Screenshot | On-screen pt | Native units in source |
|---|---|---|---|
| Trio ring outer diameter | 102 px | 51 pt | 252 (243 + 9 stroke) |
| Trio ring stroke | 4 px | 2 pt | `ringLineWidth` 9 |
| Trio "128" cap height | 23 px | 11.5 pt | `glucoseFontSize` 84 -> 17.1 pt font |
| Trio "1m -6" cap height | **9 px** | **4.5 pt** | `secondLineFontSize` 31 -> **6.3 pt font** |
| Trio trend arrow (visible wedge) | **12 x 7 px** | **6 x 3.5 pt** | `triangleSize` 30, visible depth 15 |
| Dexcom circular "128" cap height | 26 px | 13 pt | (~19 pt font, non-rounded) |
| Trio accessoryCorner secondary "1M" cap height | 15-17 px | 7.5-8.5 pt | (~11-12 pt font) |

Dexcom's trend arrow could not be measured -- the watch hands cover it in this capture.

### What the numbers say

1. **The primary number is only ~12% smaller than Dexcom's** (23 px vs 26 px cap). It is not the main problem, though it is not filling the space either.
2. **The secondary line is the real defect.** At a **6.3 pt font / 4.5 pt cap height** it is roughly **half** the size of the same information on Trio's own `accessoryCorner` complication (~11-12 pt), and well under any watchOS text style (`caption2` is 12 pt).
3. **The trend arrow is 6 x 3.5 pt** -- only ~1.75x the ring's own 2 pt stroke width, sitting immediately inside the ring. At that size it reads as a thickening of the ring, not as an arrow.
4. **The fonts are not actually width-limited by the anti-overlap tuning, for typical mg/dL values.** Measured, "128" at `glucoseFontSize` 84 occupies **113 of the 159** native units `textWidth` allows (29% spare), and "1m -6" occupies **74 of 159** (53% spare). The fixed sizes 84/31 appear to have been chosen for the worst-case string (mmol/L, e.g. "12.8" and "59m -0.6"), with `minimumScaleFactor` never getting a chance to help because the base size is already small enough to always fit.

### Where the space goes

Inside the 256-unit canvas (`.insideRing` placement):

- ring outer radius 126 of 128 -- the ring itself is already maximal
- ring inner radius **117** -- this is the real drawable bound for content
- `triangleBaseRadius` = 117 - 15 = **102** -- the arrow orbits the annulus r=102..117
- `textWidth` = 2 x 102 x 0.78 = **159** -- i.e. 62% of the canvas width, 68% of the ring's inner diameter

Commit b471e2292 ("keep inside-ring text clear of a 45 degree arrow") reduced `textWidth` from `2 * (triangleBaseRadius - 4)` = 196 to `2 * triangleBaseRadius * 0.78` = 159, a **19% narrowing**, to stop the arrow clipping the text block's corners at +/-45 degrees.

Geometric check of how much that clearance actually buys, per trend direction:

- **0 / 180 degrees** (Flat): arrow occupies x=102..117, |y|<=15. Even at the pre-b471e2292 width (half-width 98) the text never reaches x=102. **No overlap either way** -- the clearance is doing nothing here.
- **+/-90 degrees** (SingleUp / SingleDown -- the common non-flat cases): arrow occupies |y|=102..117 at x~0. The two-line stack is ~142 native tall, i.e. |y| <= 71. **No overlap either way.**
- **+/-45 degrees**: the arrow's base sits around (72, +/-72). Only here does it reach the text *box* corner, and the intersection is a sliver of roughly 14 x 10 native units = **5.6 x 4 px on screen**, at a corner where the glyphs themselves are usually absent.

So the operator's reading is correct: the clearance rule costs 19% of the text box on every reading, to avoid a sub-6 px corner graze on two of nine trend directions.

## Plan (not yet implemented -- needs operator sign-off on the options below)

Two files, two patches:

- `Trio/Sources/Services/ContactImage/GlucoseBobbleContactView.swift` -> **patch 03** (`feature/glucose-bobble-shared`)
- `Trio Watch Complication/GlucoseBobbleComplication.swift`, `Trio/Sources/Models/GlucoseBobbleComplicationSettings.swift`, `Trio/Sources/Modules/WatchConfig/View/GlucoseBobbleComplicationSettingsView.swift` -> **patch 04** (`feature/glucose-circular-complication`)

**Hard constraint:** `GlucoseBobbleContactView` is shared with the phone's contact image and the HUD bobble via `.outsideRing`. `Layout.triangleSize` and `Layout.nativeSize` are consumed by both placements, and the source comment records that `triangleSize` 30 is near the ceiling at which `ImageRenderer` clips the tip for `.outsideRing`. Any size increase must therefore be moved onto `TrendArrowPlacement` (as `ringDiameter` / `glucoseFontSize` / `secondLineFontSize` already are), leaving `.outsideRing` byte-identical in behaviour.

### Step 1 -- drop the 45-degree clearance, bound the text by the ring instead

`TrendArrowPlacement.textWidth` for `.insideRing`: replace `2 * triangleBaseRadius * 0.78` (159) with a bound derived from the ring's inner radius (117), i.e. up to **~196-234**. Expected gain: **+23% to +47% usable text width**, at the cost of the sliver overlap quantified above. This is the change the operator has explicitly authorised.

### Step 2 -- raise the base font sizes and let `minimumScaleFactor` handle the long strings

This is the change that actually makes the text bigger; step 1 only creates the room for it.

- `glucoseFontSize` 84 -> **~105-118** (17.1 pt -> 21.3-24.0 pt on screen; cap height 23 px -> 29-32 px, i.e. **comfortably past Dexcom's 26 px**)
- `secondLineFontSize` 31 -> **~50-53** (6.3 pt -> 10.1-10.8 pt; cap height 9 px -> 14-15 px, i.e. **matching the accessoryCorner complication's ~15-17 px**)
- `vStackSpacing` 5 -> ~6

With the wider box from step 1, a worst-case mmol string ("12.8" / "59m -0.6") still fits or degrades gracefully via the existing `minimumScaleFactor(0.4)` / `(0.5)`. That is the correct failure mode: shrink only when the value is genuinely long, instead of shrinking always.

Exact values want one Xcode-preview iteration across the existing four previews plus an mmol case -- the numbers above are derived from the measured glyph metrics, not from a render.

### Step 3 -- make the trend arrow visible

`triangleSize` 30 -> **~56-60** for `.insideRing` only (moved onto `TrendArrowPlacement`), giving **22-24 x 12-14 px** on screen (11-12 x 6-7 pt) instead of 12 x 7 px. Two sub-options for placement, needs an operator call:

- **(a) keep it orbiting inside the ring**, with `triangleBaseRadius` recomputed from the larger triangle (117 - 28 = 89). Minimal change; the arrow intrudes further into the text's circle, which step 1 has already accepted.
- **(b) centre it on the ring stroke** so it reads as an arrowhead on the ring rather than a nub inside it. Visually crisper and frees the whole interior for text, but is a larger change to `triangleOffset`.

### Step 4 (optional) -- expose a size control instead of guessing

`GlucoseBobbleComplicationSettings` already decodes with `decodeIfPresent` + defaults, so adding a field is backward-compatible with snapshots already on the watch. A `textSize: .small | .medium | .large` (multiplier on the two font sizes) would let the operator tune on-wrist rather than us iterating through TestFlight builds. Costs: one field, one Picker in `GlucoseBobbleComplicationSettingsView`, and it rides the existing watch-state transport in patch 04 -- no new plumbing.

Worth doing only if steps 1-3 do not settle it on the first build; flagged here so the option is on record.

### Step 5 -- ship

`mid-stack-update.sh --patch 03` and `--patch 04` with the respective cherry-picks, then `patch-test.sh` (which runs `patch-audit.sh`), then a build on explicit operator request.

## Open questions for the operator

1. Arrow placement: step 3 option (a) inside the ring, or (b) on the ring?
2. How far to push the primary number -- to roughly Dexcom's size (~26 px cap), or past it (~32 px cap) given the ring already costs 2 pt of radius?
3. Do you want the size control (step 4) in the same build, or only as a fallback?

## Second screenshot (2026-09-27, glucose 199, trend FortyFiveUp) -- the Dexcom arrow

The operator supplied a second face capture in which the watch hands do not cover the Dexcom subdial. This one was not persisted to disk, so the figures below are a **visual estimate against the anchors measured from the first capture** (circular slot = 102 px, Dexcom digit cap = 26 px), not a pixel measurement. Treat the ratios as solid and the absolute px values as +/- 20%.

| | Trio circular (measured) | Dexcom circular (estimated) |
|---|---|---|
| Trend arrow height | **7 px** (visible wedge depth), 12 px wide | **~20 px** |
| Arrow height / own digit cap height | 7 / 23 = **0.30** | ~20 / 26 = **~0.77** |

The ratio row is the robust comparison -- both are read the same way, so it survives the estimation error. **Dexcom draws its trend arrow at roughly three quarters of its glucose digits' cap height; Trio draws it at under a third.** That, not the absolute pixel count, is the design difference.

### This capture is the +/-45 degree case the clearance rule was written for

Trend is FortyFiveUp, so `rotationDegrees` = -45 and the arrow sits at the ring's upper right -- precisely the orientation commit b471e2292 narrowed `textWidth` by 19% to protect. In the capture:

- the arrow is a barely-perceptible tick on the ring, not a readable direction indicator
- "199" and "9m +7" are nowhere near it; the reserved corner is visibly empty

So the +/-45 degree case, observed rather than calculated, confirms the geometry above: the clearance is buying empty space, and the thing it was protecting the text from is too small to see in the first place.

Consequence for the plan: step 3 (arrow size) is now the **highest-value** change of the three, and its target can be stated as a ratio rather than a guess -- **the trend arrow should be ~0.7x the glucose digits' cap height**, matching Dexcom. With the step-2 target of a 29-32 px cap, that is a ~20-22 px arrow, i.e. `triangleSize` roughly 30 -> **100-110 native units** for `.insideRing` (visible depth is half of `triangleSize`). That is substantially larger than the 56-60 estimated before this capture, and it makes option (b) -- centring the arrow on the ring stroke rather than orbiting it inside -- the more likely workable choice, since an arrow that deep orbiting inside the ring would reach r=117-55=62 and genuinely collide with the text.

## Dexcom arrow, measured (199 capture, recovered from ~/Downloads)

The 199 capture was found on disk as `~/Downloads/incoming-F3589234-0727-4C37-AF99-5ACB418B028E.PNG` (AirDrop). It is a **16-bit HDR PNG** (`IHDR` bit depth 16, `cICP` present), unlike the first capture's 8-bit sRGB -- a decoder that assumes 8 bits produces noise, not an image.

| | Trio circular | Dexcom circular |
|---|---|---|
| Glucose digits, cap height | 22 px | **26 px** |
| Glucose digits, stroke width | **5-6 px** | **3 px** |
| stroke / cap ratio | **0.24** | **0.115** |
| Trend arrow, bounding box | 12 x 7 px | **22 x 21 px** |
| arrow height / digit cap height | **0.30** | **0.81** |

### Correction to the earlier arrow-size estimate

The previous note derived `triangleSize` 100-110 by equating the triangle's *radial depth* with the Dexcom glyph's *full height*. That is the wrong comparison: Trio's arrow is a filled wedge (width T, depth T/2) and Dexcom's is a stroked glyph that is mostly empty. Matching **ink area** instead: a wedge at T=60 is 24 x 12 px = ~144 px of fill, against ~115 px of stroke ink in Dexcom's 22 x 21 px arrow. So the target is **`triangleSize` ~56-70**, as originally estimated, not 100-110.

### Gotcha: `Triangle` does not scale uniformly

`Trio/Sources/Views/Triangle.swift` hardcodes two absolute constants in its path:

```swift
path.move(to: CGPoint(x: rect.midX, y: rect.minY + 15))
path.addQuadCurve(..., control: CGPoint(x: rect.midX, y: rect.midY + 10))
```

At `frame(30x30)` the tip lands exactly on the frame centre, so the visible arrow is `triangleSize / 2` deep -- which is what the `GlucoseBobbleContactView` comment records. At `frame(64x64)` the tip is still only 15 from the top, so the visible arrow becomes 49 deep, not 32: **the wedge gets proportionally pointier as `triangleSize` grows.** `Triangle` is also used by `CurrentGlucoseView` (the HUD) and by the `.outsideRing` contact image, so its path must not change.

Implementation consequence: size the arrow with `.scaleEffect` on a fixed `frame(30x30)` triangle (preserves the shape exactly), or add a placement-specific shape. Do **not** simply raise `triangleSize`.

## Mockup

`docs/in-progress/watch-glucose-bobble-complication/arrow-placement-mockup.html` (+ rendered `mockup.png`). Geometry is generated from `GlucoseBobbleContactView.Layout`'s 256-unit canvas, drawn at 4x, 3x and at **true size (102 px)**. Variants: A current, B bigger arrow inside a continuous ring, C bigger arrow with a gap cut in the ring ("on the ring"), D no ring at all. Plus rows for font weight and background tint opacity.

Finding from building it: there is **no meaningful "outside" the ring**. The ring's outer edge is at radius 126 of the 128-unit half-canvas, so an arrow cannot sit beyond it without being clipped by the complication's circular mask. "On the ring" can only mean *cutting a gap in the ring and seating the arrow in it* (variant C), which is what the mockup shows.

## Question 2 -- is the number bold?

Yes. `GlucoseBobbleContactView` uses `.font(.system(size:, weight: .bold, design: .rounded))` for **both** lines. Measured stroke/cap ratio 0.24 against Dexcom's 0.115, so Trio's digits carry roughly twice the relative stroke weight, and `design: .rounded` is wider per unit of cap height than SF. At a 22 px cap the counters (the enclosed holes in 8, 9, 6) close up, which is the legibility loss the operator is seeing.

Dropping to `.semibold`/`.medium` and/or `design: .default` **also frees width**, so it permits a larger cap height in the same box -- the two changes compound rather than trade off. Cost: the complication stops matching the HUD bobble's and contact image's rounded look.

## Question 3 -- Contact Image config vs Glucose Bobble complication config

`ContactImageEntry` (`Trio/Sources/Models/ContactTrickEntry.swift`, 20 fields) against `GlucoseBobbleComplicationSettings` (5 fields):

| Contact Image | Bobble complication | Verdict |
|---|---|---|
| `fontSize` (tiny 200 / small 250 / regular 300 / large 400) | **missing** -- hardcoded 84 | **port it** |
| `secondaryFontSize` (same scale) | **missing** -- hardcoded 31 | **port it** |
| `fontWeight` (`Font.Weight`) | **missing** -- hardcoded `.bold` | **port it** |
| `fontWidth` (`Font.Width`) | **missing** -- hardcoded standard | port it (cheap) |
| `ringWidth` (tiny 3 … large 15) | **missing** -- hardcoded `ringLineWidth` 9 | port it (cheap) |
| `ring` (Hidden / Loop) | `ringStyle` (Trend Gradient / Loop Status) | present, different semantics -- keep both |
| `colorMode` (color / monochrome) | `colorMode` (Dynamic / White) | present, different meaning |
| `backgroundMode` (transparent / black) | `backgroundStyle` (Glucose Tint / System / None) | present, complication-appropriate |
| `ringGap` | missing | not meaningful for the bobble layout |
| `hasHighContrast` | missing | arguably redundant at complication size |
| `layout` (default / split / bobble) | n/a | complication is bobble-only by design |
| `primary` / `top` / `bottom` (8 value types) | `showMinutesAgo` / `showDelta` booleans | complication content is fixed; booleans are the right scope |
| `name`, `contactId` | n/a | contact bookkeeping |

**`FontSize`'s raw values are canvas fractions, so they port directly.** 200/250/300/400 are sizes on the contact image's 1024 canvas; scaled to the complication's 256 canvas they become **50 / 62.5 / 75 / 100**. The current hardcoded 84 sits between `regular` (75) and `large` (100), so reusing the enum as-is tops out at only +19% over today. **An additional case above `large` is needed** for this task's target of ~110.

## Question 4 -- does the background tint follow the glucose colour?

**Yes, exactly.** Measured in both captures, and the arithmetic closes to the byte:

| Capture | Glucose digits | Background | 0.30 x digits over black |
|---|---|---|---|
| 128 | `#5BE5C0` | `#1B453A` | `#1B4539` |
| 199 | `#665BDD` | `#1F1B42` | `#1F1B42` |

So `Circle().fill(snapshotGlucoseColor.opacity(0.3))` is doing precisely what it says. It reads as muted because **0.30 alpha over black is muted**, not because the colour is wrong.

### The phone preview is hardcoded green -- this is a bug

`GlucoseBobbleComplicationSettingsView` never uses the live glucose colour:

```swift
private var sampleGlucoseColor: Color {
    switch state.glucoseBobbleComplication.colorMode {
    case .glucose: return .green      // always green
    case .white:   return .white
    }
}
...
case .glucoseTint:
    Circle().fill(Color.green.opacity(0.3))   // always green
```

That is why the phone preview shows green while the watch shows indigo. It should read the current glucose colour, the way the contact-image preview does. Worth fixing as part of this task regardless of the sizing work.

### What the low end actually shows: red, not yellow

From `Trio/Sources/Helpers/DynamicGlucoseColor.swift`, `calculateHueBasedGlucoseColor` interpolates **hue** at fixed saturation 0.6 / brightness 0.9:

- at or below `lowGlucose` -> hue 0 deg, **red**
- `lowGlucose` -> `targetGlucose` -> interpolates red (0 deg) to green (120 deg), so it passes through orange and yellow on the way up
- `targetGlucose` -> `highGlucose` -> interpolates green (120 deg) to purple (270 deg), passing teal, blue, indigo
- at or above `highGlucose` -> hue 270 deg, **purple**

The measured values fit: 128 -> hue 164 deg (teal, just above target), 199 -> hue 245 deg (indigo, most of the way to high). So the complication is faithfully rendering Trio's `.dynamicColor` scheme. It does **not** match the Dexcom convention (Dexcom uses yellow for high, red for low, grey in range). `GlucoseColorScheme.staticColor` is the alternative Trio already ships: red low / green in range / purple high -- closer to Dexcom's mental model but still purple, not yellow, at the top.

### Why the green 128 "looks funny"

Contrast is not the problem numerically -- `#5BE5C0` on `#1B453A` is **6.85:1**, comfortably past WCAG AA. The problem is that the number and its background are **the same hue**: the digits are just a lighter version of the backdrop, so there is no chromatic separation, only luminance.

White digits on the same background measure **10.7:1** and add hue separation, while the background still carries the glucose colour (the code comments already note the tint uses the raw glucose colour even when the number is forced white).

**The operator can test this today with no build:** Glucose Bobble Complication settings -> Glucose Color -> **White**.

### Tint vibrancy options

The mockup's tint row shows 0.30 (current) / 0.45 / 0.60 / none at true size. 0.45-0.55 reads as clearly coloured without swamping white text. Options, in increasing cost:

1. Raise the constant from 0.30 to ~0.50.
2. Make it a setting (`backgroundTint: subtle | medium | vivid`), consistent with step 4's size control.
3. Leave it and switch the number to white, which fixes the same-hue problem without touching the background at all.

## Revised recommendation

1. Number size is roughly fine per the operator -- the changes that matter are **arrow size** (0.30 -> ~0.7 of cap height), **second-line size** (6.3 pt -> ~10-11 pt) and **weight** (bold -> semibold/medium).
2. Ship the size control (question 3) by porting `fontSize` / `secondaryFontSize` / `fontWeight` / `fontWidth` / `ringWidth` from `ContactImageEntry`, adding one `FontSize` case above `large`.
3. Fix the hardcoded-green preview.
4. Arrow placement: operator to choose from the mockup (A/B/C/D).
5. Background: operator to choose tint opacity, and try Glucose Color = White first.


## Open design question: double arrows (2026-10-09)

DoubleUp and TripleUp render exactly like SingleUp (one wedge at -90 degrees), and DoubleDown and TripleDown like SingleDown (+90), in `GlucoseBobbleContactView.rotationDegrees(forTrend:)` and in the phone HUD (`CurrentGlucoseView`). Only the VoiceOver label tells them apart ("rising quickly" vs "rising"). Dexcom draws two arrows for a double. Decide whether the circular complication should show a second wedge (or a longer or brighter one) for double and triple trends; at 51 pt this is the most safety-relevant state to read at a glance. The design picker (https://claude.ai/artifact/SBVFLLuYLcf8qz2btAkoQL) does not show it yet.
