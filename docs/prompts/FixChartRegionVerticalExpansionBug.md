## Task: Fix Chart Region Vertical Expansion Bug

### Problem Description

The glucose/basal/COB chart region in the Home view occasionally grows too tall during normal app usage, remaining oversized until the app is force-quit. The issue is **suspected to be caused by**:

1. **Unconstrained `Spacer()` views** inside `VStack`s that can expand to fill available space when SwiftUI recalculates layout.
2. **No height constraint on the outer chart container** (a `ZStack` overlaying two `VStack`s), allowing the overall chart region to grow beyond the intended sum of its components.
3. **Use of `minHeight` instead of fixed `height`** on chart frames, permitting charts to expand when the parent offers extra vertical space.

**Alternative / contributing causes** (not fully ruled out; must be investigated and either confirmed or explicitly ruled out in output):
- `safeAreaSize` changes at runtime (notably toggling between `0` and `0.08` based on notification permission status), which changes `mainChartHeight` and can cause visible jumps.
- Parent geometry changes (safe area insets, overlays, banners, sheet presentations, notification banners, etc.) changing `GeometryReader` height and thus the computed chart heights.

### Success Criteria

1. Chart region height does **not** grow unexpectedly across state updates, view invalidations, or layout recalculations.
2. Overlay alignment stays pixel-aligned between dummy charts (static Y-axis overlay) and scrollable charts.
3. Dynamic Type changes do not cause clipping, overlap, or layout breakage (especially around axis/label regions).
4. No visual regressions across common device sizes (small phones to large phones) and orientations supported by the app.
5. If `safeAreaSize` or parent geometry changes, any chart resize is **bounded, deterministic, and explainable**, not “unbounded growth”.

### Files to Modify

- `Trio/Sources/Modules/Home/View/Chart/MainChartView.swift`
- `Trio/Sources/Modules/Home/View/Chart/ChartElements/BasalChart.swift`
- `Trio/Sources/Modules/Home/View/Chart/ChartElements/CobIobChart.swift`
- `Trio/Sources/Modules/Home/View/Chart/ChartElements/DummyCharts.swift`

### Must Inspect (Read-Only Investigation)

You **must** inspect these files to validate/rule out alternative root causes and to ensure the fix is wired correctly:

- `Trio/Sources/Modules/Home/View/HomeRootView.swift`
  - Identify where `safeAreaSize` comes from, and under what conditions it changes.
  - Identify any parent layout changes that could change `MainChartView`’s `GeometryReader` height (e.g., conditional banners/sections above/below charts, permission prompts, dynamic lists that appear/disappear).

- `Trio/Sources/Modules/Home/View/Chart/MainChartView.swift`
  - Identify the exact chart container structure (outer `ZStack`, inner `VStack`s, spacers, and any `.frame` modifiers).
  - Confirm which charts use `minHeight` and where alignment depends on matching heights between “dummy/static” and “real/scrollable”.

Your output must include a short “Investigation Results” section stating:
- Whether `safeAreaSize` can change at runtime, and why.
- Whether parent geometry can change at runtime in the Home view, and why.
- Whether the fix fully prevents unbounded height growth even if those inputs fluctuate.

### Do Not Change

- Chart drawing logic (marks, colors, data bindings).
- Axis definitions or scale calculations.
- Data fetching, state management, or persistence logic.
- Any files outside the four “Files to Modify” list **except** read-only inspection of `HomeRootView.swift`.

### Allowed (Small, Targeted Additions)

- A **temporary debug-only diagnostic log** (behind `#if DEBUG`) to print `geo.size.height`, `safeAreaSize`, and computed heights when they change, to confirm whether the suspected triggers happen in practice.
- Non-functional comments that explain the layout contract and why the constraints exist.

---

## Required Changes

### 1) In `MainChartView.swift`

#### A. Add layout constants + chart stack sizing (near other view properties)

Add these properties after the existing `@Environment` declarations:

```swift
// Scaled spacer height for accessibility support - scales with dynamic type.
@ScaledMetric(relativeTo: .footnote) private var axisSpacerHeight: CGFloat = 16

// Fixed spacing between chart components.
private let chartSpacing: CGFloat = 5

// Computed chart stack height to constrain the overall chart region.
// Layout inside each VStack: basalChart, mainChart, axisSpacer, cobChart = 4 items with 3 gaps.
private var chartStackHeight: CGFloat {
    basalChartHeight + mainChartHeight + cobChartHeight + axisSpacerHeight + (chartSpacing * 3)
}

B. Ensure chart heights are fixed (not minHeight) and are guarded
Add (or update) computed height properties. They must be fixed heights with a clamp to avoid negative values:

// NOTE:
// Historically these charts used `minHeight` to allow them to stretch if the
// surrounding layout provided extra vertical space. The flexible sizing also
// meant that a spacer recalculation or an unexpected safe-area change could
// cause the charts to over-expand. We now use fixed heights to keep the
// overlaid chart stack aligned. If future layouts need flexibility again,
// prefer a bounded range (`minHeight` + `maxHeight`) instead of a single
// unconstrained `minHeight`.

private var mainChartHeight: CGFloat {
    max(geo.size.height * (0.28 - safeAreaSize), 0)
}

private var basalChartHeight: CGFloat {
    max(geo.size.height * 0.05, 0)
}

private var cobChartHeight: CGFloat {
    max(geo.size.height * 0.12, 0)
}

Important: keep these as single source of truth and reuse them in all chart frames (real + dummy), so overlays cannot drift.

C. Constrain the outer chart container height and remove flexible spacers
In the body layout where the charts are stacked/overlaid:
	1.	Change both VStack(spacing: 5) to use the constant:

VStack(spacing: chartSpacing) { ... }

	2.	Replace any Spacer() used between chart components (in both VStacks) with a fixed-size spacer that cannot expand:

Color.clear.frame(height: axisSpacerHeight)

	3.	Add a height constraint to the outer ZStack that overlays the two VStacks:

ZStack {
    // ... existing content ...
}
.frame(height: chartStackHeight)

This is the key guardrail: even if SwiftUI offers more vertical space later, the chart region should remain bounded to the intended sum of components.

D. Update chart frames to fixed heights
In the mainChart computed property (and anywhere else it exists), change:
	•	From:

.frame(minHeight: geo.size.height * (0.28 - safeAreaSize))


	•	To:

.frame(height: mainChartHeight)



E. Optional (debug-only) diagnostics
If the issue is hard to reproduce, add a temporary #if DEBUG diagnostic that prints whenever the computed heights change (or whenever safeAreaSize changes). Keep it small, and ensure it cannot ship in Release builds.

Example pattern (do not add unless needed):
	•	print geo.size.height, safeAreaSize, mainChartHeight, chartStackHeight
	•	only in DEBUG

⸻

2) In BasalChart.swift

Change any minHeight usage to fixed height using the shared computed property:
	•	From:

.frame(minHeight: geo.size.height * 0.05)


	•	To:

.frame(height: basalChartHeight)



⸻

3) In CobIobChart.swift

Change any minHeight usage to fixed height using the shared computed property:
	•	From:

.frame(minHeight: geo.size.height * 0.12)


	•	To:

.frame(height: cobChartHeight)



⸻

4) In DummyCharts.swift

For all three dummy charts (staticYAxisChart, dummyBasalChart, dummyCobChart):
	•	Replace any .frame(minHeight: ...) with the corresponding fixed height property:
	•	.frame(height: mainChartHeight)
	•	.frame(height: basalChartHeight)
	•	.frame(height: cobChartHeight)

The dummy/static charts and the real/scrollable charts must use the same fixed height inputs or overlays can drift and appear “misaligned”.

⸻

Design Rationale
	1.	Fixed heights instead of minHeight: prevents charts from growing when SwiftUI recomputes layout or when extra space becomes available.
	2.	No Spacer() inside the chart stacks: prevents uncontrolled expansion during layout recalculation.
	3.	@ScaledMetric for spacer height: keeps the inter-chart separation accessible under Dynamic Type without using flexible Spacer().
	4.	Computed chartStackHeight applied to the outer ZStack: prevents the container from stretching unbounded regardless of parent geometry behavior.
	5.	Centralized chartSpacing constant: makes the layout contract explicit and maintainable.

⸻

Important Notes
	•	Spacing calculation: chartSpacing * 3 because there are 4 items (basalChart, mainChart, axisSpacer, cobChart) with 3 gaps.
	•	Spacer counted once: the axisSpacerHeight is part of each VStack, but the two stacks are overlaid (not stacked vertically), so the container height should reflect a single stack’s vertical structure.
	•	Height guards: keep max(..., 0) to avoid negative heights on unusual geometry/safe area states.
	•	Visibility: keep height properties private unless they must be referenced externally (they typically should not be).
	•	If safeAreaSize toggles: the fix should still keep behavior bounded. If the app still “jumps” in height when permissions change, that is acceptable only if it is deterministic and does not break alignment.

⸻

Verification

After implementing these changes:
	1.	The chart region maintains a consistent, bounded height during normal usage; no unbounded vertical growth occurs.
	2.	Dummy/static and scrollable charts remain aligned (no vertical drift).
	3.	Dynamic Type changes do not clip axes/labels or cause overlap; the inter-chart gap scales appropriately.
	4.	No regressions across device sizes.
	5.	If notification permission changes and safeAreaSize toggles, any resulting height change is bounded and does not cause the region to “run away” in size.
	6.	If the bug persists, enable the debug diagnostics and capture:
	•	geo.size.height
	•	safeAreaSize
	•	mainChartHeight, basalChartHeight, cobChartHeight
	•	chartStackHeight
at the moment the chart becomes oversized.

