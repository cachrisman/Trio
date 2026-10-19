+++
uid = "01a1558c-e2ea-767f-bc12-c87bf450a0b4"
key = "TRIO-086"
title = "Live Activity: big-glucose lock-screen style (layout B) as a new Lock Screen Widget Style option"
status = "review"
kind = "code"
source = "human"
created = 2026-10-19
updated = 2026-10-19
touched = 2026-10-19
tags = ["live-activity", "ui"]
files = ["LiveActivity/Views/LiveActivityView.swift", "Trio/Sources/Models/LockScreenView.swift"]
parent = "01a15580-dcde-70fd-902f-5bcb7d48cb9f"
priority = 3

[[acceptance]]
id = "AC-1"
text = "LockScreenView gains a Big Glucose case that the Lock Screen Widget Style picker offers as a third option; the Watch/CarPlay Widget Style picker still offers only Simple and Detailed."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "feature/live-activity-big-glucose 8b0257151 + b36f51e2e: LockScreenView.bigGlucose; RootView Lock Screen picker uses allCases, Watch/CarPlay picker filters out .bigGlucose; TrioSettings decode maps persisted smartStackView .bigGlucose to .simple. codex-work review pass fbff7387 after fail a2f9c389. Re-pinned 2026-10-19 after merging origin/dev into dev (9f7f9560b): LiveActivity/LiveActivity.swift on dev is identical to the branch base bcebda2f5, and patch 19 applies cleanly on top (patch-test PASSED)."
met_at = 2026-10-19
met_ts = "2026-10-19T22:28:31+02:00"
met_by = "claude-code"
met_commit = "9f7f9560b675c1e725b7a642de0a0f1972dde09e"

[[acceptance]]
id = "AC-2"
text = "ContentState carries an optional big-glucose style (font size + colour-by-range) that is set only when the lock-screen style is Big Glucose; existing ContentState call sites (preview initialisers, LiveActivityManager) keep their meaning."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "feature/live-activity-big-glucose 8b0257151 + b36f51e2e: ContentState.bigGlucoseViewStyle: BigGlucoseViewStyle? = nil (memberwise default keeps existing call sites), set in init(new:) only when lockScreenView == .bigGlucose. codex-work review pass fbff7387 after fail a2f9c389. Re-pinned 2026-10-19 after merging origin/dev into dev (9f7f9560b): LiveActivity/LiveActivity.swift on dev is identical to the branch base bcebda2f5, and patch 19 applies cleanly on top (patch-test PASSED)."
met_at = 2026-10-19
met_ts = "2026-10-19T22:28:31+02:00"
met_by = "claude-code"
met_commit = "9f7f9560b675c1e725b7a642de0a0f1972dde09e"

[[acceptance]]
id = "AC-3"
text = "Big Glucose lock-screen layout: glucose value on the left (76pt at the default size, lineLimit 1 + minimumScaleFactor so mmol/L shrinks to fit) with trend arrow and delta beneath it; ~180pt-wide chart on the right; one line under the chart reading IOB U · COB g · updated time; stale readings struck through as in the other styles; the initial/expired state shows the existing expired message."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "feature/live-activity-big-glucose 8b0257151 + b36f51e2e: LiveActivityBigGlucoseView in LiveActivityView.swift — value at bigGlucosePointSize (large=76) lineLimit 1 + minimumScaleFactor 0.4, arrow+delta beneath, 180pt chart column, 'IOB U · COB g · time' line, strikethrough when stale, expired text for initial state; previews incl. mmol/L and expired. Not compiled (no xcodebuild per brief). codex-work review pass fbff7387 after fail a2f9c389. Re-pinned 2026-10-19 after merging origin/dev into dev (9f7f9560b): LiveActivity/LiveActivity.swift on dev is identical to the branch base bcebda2f5, and patch 19 applies cleanly on top (patch-test PASSED)."
met_at = 2026-10-19
met_ts = "2026-10-19T22:28:31+02:00"
met_by = "claude-code"
met_commit = "9f7f9560b675c1e725b7a642de0a0f1972dde09e"

[[acceptance]]
id = "AC-4"
text = "Big Glucose glucose value (and arrow/delta) is primary/white by default and uses the glucose range colour only when the new colour-by-range setting is on."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "feature/live-activity-big-glucose 8b0257151 + b36f51e2e: valueColor = colorByRange ? glucoseColor : .primary (.secondary when stale); BigGlucoseViewStyle.default colorByRange false. codex-work review pass fbff7387 after fail a2f9c389. Re-pinned 2026-10-19 after merging origin/dev into dev (9f7f9560b): LiveActivity/LiveActivity.swift on dev is identical to the branch base bcebda2f5, and patch 19 applies cleanly on top (patch-test PASSED)."
met_at = 2026-10-19
met_ts = "2026-10-19T22:28:20+02:00"
met_by = "claude-code"
met_commit = "9f7f9560b675c1e725b7a642de0a0f1972dde09e"

[[acceptance]]
id = "AC-5"
text = "The Big Glucose chart shows ~3h of history and at most ~1.5h of forecast (B2); the Detailed lock-screen, Dynamic Island and Watch chart windows are unchanged."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "feature/live-activity-big-glucose 8b0257151 + b36f51e2e: LiveActivityChartView.isCompactWindow (default false) — 3h history for drawing and y-scale, forecasts prefixed to 19 points (~1.5h); all non-compact paths unchanged. codex-work review pass fbff7387 after fail a2f9c389. Re-pinned 2026-10-19 after merging origin/dev into dev (9f7f9560b): LiveActivity/LiveActivity.swift on dev is identical to the branch base bcebda2f5, and patch 19 applies cleanly on top (patch-test PASSED)."
met_at = 2026-10-19
met_ts = "2026-10-19T22:28:21+02:00"
met_by = "claude-code"
met_commit = "9f7f9560b675c1e725b7a642de0a0f1972dde09e"

[[acceptance]]
id = "AC-6"
text = "Big Glucose font size and colour-by-range are TrioSettings fields (decoded with defaults when absent, included in settings export) edited on a Widget Configuration screen linked from Live Activity settings when Big Glucose is selected."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "feature/live-activity-big-glucose 8b0257151 + b36f51e2e: TrioSettings liveActivityBigGlucoseFontSize/.liveActivityBigGlucoseColorByRange with try? decode defaults; SettingsExport block; LiveActivityBigGlucoseWidgetConfiguration linked from RootView when .bigGlucose. codex-work review pass fbff7387 after fail a2f9c389. Re-pinned 2026-10-19 after merging origin/dev into dev (9f7f9560b): LiveActivity/LiveActivity.swift on dev is identical to the branch base bcebda2f5, and patch 19 applies cleanly on top (patch-test PASSED)."
met_at = 2026-10-19
met_ts = "2026-10-19T22:28:21+02:00"
met_by = "claude-code"
met_commit = "9f7f9560b675c1e725b7a642de0a0f1972dde09e"

[[acceptance]]
id = "AC-7"
text = "Patch 19 is generated with scripts/generate-patch.sh from the feature branch, and the stack 01-19 applies cleanly (scripts/patch-test.sh including the deletion audit, and git am --3way onto origin/dev, the build-233 base)."
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "run"
evidence = "2026-10-19: scripts/patch-test.sh on dev 9f7f9560b (local dev merged with origin/dev 744a74d04, 1.0.2.11, the build-233 base): all 16 patches 01-19 applied with git am --3way incl. patches/19-live-activity-big-glucose.patch; patch-audit PASSED (47 warnings), sentinel symbols present"
met_at = 2026-10-19
met_ts = "2026-10-19T22:27:52+02:00"
met_by = "claude-code"
met_commit = "9f7f9560b675c1e725b7a642de0a0f1972dde09e"

[[acceptance]]
id = "AC-8"
text = "On device: the Big Glucose Live Activity renders correctly on the lock screen in mg/dL and mmol/L, fresh and stale, with the colour toggle off and on, at each font size."
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-19

[[acceptance]]
id = "AC-9"
text = "Visual check of the Live Activity settings: Big Glucose in the Lock Screen picker, absent from the Watch/CarPlay picker, and its Widget Configuration screen (preview, font size, colour toggle) looks right."
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-19

[[sessions]]
host = "claude-code"
ref = "20261019-215616-direct-8b0257151"
model_family = "claude"
started = 2026-10-19
role = "author"
started_at = "2026-10-19T19:56:17+00:00"

[[sessions]]
host = "claude-code"
ref = "20261019-220157-direct-b36f51e2e"
model_family = "claude"
started = 2026-10-19
role = "author"
started_at = "2026-10-19T20:01:57+00:00"

[[reviews]]
run_id = "a2f9c389-9fd2-4978-a6a1-d4e268be7b31"
model_family = "codex"
verdict = "fail"
reviewed_commit = "8b02571515ca5fa66200ba13c68575958191bba9"
reviewed_paths = ["LiveActivity/LiveActivity.swift", "LiveActivity/Views/LiveActivityChartView.swift", "LiveActivity/Views/LiveActivityView.swift", "Trio/Sources/Models/LockScreenView.swift", "Trio/Sources/Models/TrioSettings.swift", "Trio/Sources/Modules/LiveActivitySettings/LiveActivitySettingsStateModel.swift", "Trio/Sources/Modules/LiveActivitySettings/View/LiveActivitySettingsRootView.swift", "Trio/Sources/Modules/LiveActivitySettings/View/LiveActivitySimpleWidgetConfiguration.swift", "Trio/Sources/Modules/SettingsExport/SettingsExportStateModel.swift", "Trio/Sources/Services/LiveActivity/LiveActivityAttributes+Helper.swift", "Trio/Sources/Services/LiveActivity/LiveActivityAttributes.swift", "Trio/Sources/Services/LiveActivity/LiveActivityGlucoseStyle.swift"]
recorded_at = "2026-10-19T20:02:06+00:00"

[[reviews]]
run_id = "fbff7387-8e62-4342-aba8-4916d3ecb80d"
model_family = "codex"
verdict = "pass"
reviewed_commit = "b36f51e2e4f8c888b48f5066e3902b7562c29f44"
reviewed_paths = ["LiveActivity/Views/LiveActivityChartView.swift", "Trio/Sources/Models/TrioSettings.swift"]
recorded_at = "2026-10-19T20:03:32+00:00"
+++

## Intent

## Design (operator picked layout B, 2026-10-19, mockup live-activity-big-glucose-mockups.svg)

New lock-screen Live Activity layout: glucose value (~76pt) on the left taking the full height, with trend arrow and delta (~30pt) beneath it; the chart is compressed horizontally on the right (~180pt wide), keeping glucose dots, target lines and forecast lines; a single stats line under the chart reads `IOB U · COB g · updated time`.

## Feasibility (investigated 2026-10-19)

- Fits the ~160pt Live Activity height; usable inner height ~130pt.
- Code lives in `LiveActivity/Views/LiveActivityView.swift` (new branch beside detailed/simple), `ContentState` in `LiveActivityAttributes.swift` (shared app+extension), mapping in `LiveActivityAttributes+Helper.swift`, ~12 preview initialisers in `LiveActivity.swift`.
- Settings hook: add a case to `LockScreenView` (`simple`, `detailed`, + new) so it appears in the existing "Lock Screen Widget Style" picker in `Modules/LiveActivitySettings`. `ContentState` needs a style enum (or keep `useDetailedViewIOS` and add a field). Watch Smart Stack and CarPlay unaffected.
- No patch in the stack touches Live Activity code.

## Decisions (operator, 2026-10-19)

- Staleness: strikethrough on the glucose value, as today.
- Glucose colour: white by default, with a setting to colour it by range.
- mmol/L: shrink to fit (`minimumScaleFactor`) rather than a smaller fixed size.
- Chart window: show less history so the compressed chart reads like the Home chart: ~3h history + ~1.5h forecast (B2 in live-activity-b-history-windows.svg; operator confirmed B2 2026-10-19).
- Font size: the new style gets its own font-size option, like Simple.


## Release note

New Big Glucose Lock Screen style for the Live Activity. It shows a large glucose value with the trend arrow and delta, a compact chart (about 3 hours of history and 1.5 hours of forecast), and IOB, COB and time. You can set the font size and colour the value by range in its Widget Configuration screen. A stale reading is struck through.


Shipped in build 233 (TRIO-083), uploaded to TestFlight 2026-10-19 22:55.
