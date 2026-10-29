+++
uid = "01a186d0-c4f4-7462-a3f1-b67892e8ce0c"
key = "TRIO-100"
title = "Glucose alarm notifications: optional current glucose, per-minute change and trend text; Low Glucose Soon checks the whole 20-min forecast"
status = "review"
kind = "code"
source = "human"
created = 2026-10-29
updated = 2026-10-29
touched = 2026-10-29
parent = "01a18629-b536-77bb-880c-bb88484be460"
priority = 1

[[acceptance]]
id = "AC-1"
text = "GlucoseAlertConfiguration gains showCurrentGlucose, showGlucoseDelta and showTrendDescription (default false, decodeIfPresent so existing stored configs decode), and the Glucose Alarms screen has a section with one toggle for each"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "commit"
evidence = "0bc1cdf6b — GlucoseAlertConfiguration: three Bools, default false, decodeIfPresent ?? false; GlucoseAlertsRootView: Notification Content section with three toggles"
met_at = 2026-10-29
met_ts = "2026-10-29T09:50:00+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-2"
text = "With all three toggles off, the Urgent Low, Low, High and Carbs Required bodies are exactly the current upstream text, and Low Glucose Soon differs only in naming the first crossing minute"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "commit"
evidence = "0bc1cdf6b — low/urgentLow/high: String(format: \"Glucose %1$@.\", clause) where clause == mgdl.formatted(withUnits:) with delta/trend off; carbsRequiredBody returns upstream text when showCurrentGlucose is off; forecast body is the upstream sentence with the crossing minute (tests forecastBodyOff, carbsBodyOff)"
met_at = 2026-10-29
met_ts = "2026-10-29T09:50:00+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-3"
text = "Urgent Low, Low and High bodies append the per-minute change and the trend word when those toggles are on, inside the existing 'Glucose %1$@.' string"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "commit"
evidence = "0bc1cdf6b — readingClause appends ' (±x.x/min)' and ', <trend word>' inside 'Glucose %1$@.' for urgentLow/low/high"
met_at = 2026-10-29
met_ts = "2026-10-29T09:50:01+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-4"
text = "Low Glucose Soon fires when any forecast point from +5 to +20 min is at or below the threshold, retracts only when every point in that window is at or above threshold + 5, and its body names the first crossing minute"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "commit"
evidence = "0bc1cdf6b — ForecastedGlucoseEvaluator.evaluateWindow (indices 1...4, min across curves per point); evaluateForecastBased fires on lowestPredicted <= threshold, retracts via shouldRetract(lowestPredicted); body minute = firstCrossingMinutes"
met_at = 2026-10-29
met_ts = "2026-10-29T09:50:01+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-5"
text = "Low Glucose Soon and Carbs Required bodies lead with the current glucose clause when showCurrentGlucose is on and a reading from the last 12 minutes exists; Low Glucose Soon says glucose is already below the threshold when the reading is at or below it"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "commit"
evidence = "0bc1cdf6b — forecastedLowBody / carbsRequiredBody prefix the reading clause only with showCurrentGlucose and a freshCachedReading(); 'Your glucose is already below %@.' when reading < threshold"
met_at = 2026-10-29
met_ts = "2026-10-29T09:50:01+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-6"
text = "Change per minute = (current - previous) / minutes between them, omitted when there is no previous reading or the gap is under 1 or over 15 minutes; one decimal in mg/dL, two in mmol/L, signed"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "commit"
evidence = "0bc1cdf6b — fetchLatestReading fetchLimit 2 with cutoff widened by 15 min, latest still gated at 12 min; delta only for a 1–15 min gap; NumberFormatter positivePrefix '+', 1 digit mg/dL, 2 digits mmol/L (exchangeRate, unrounded)"
met_at = 2026-10-29
met_ts = "2026-10-29T09:50:01+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-7"
text = "Unit tests cover the body builders (every toggle combination that changes text, mg/dL and mmol/L, missing reading, missing previous reading) and the forecast window (dip-and-recover, crossing minute, retract margin)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "commit"
evidence = "0bc1cdf6b — ForecastedGlucoseEvaluatorTests: 6 window tests; GlucoseAlertCoordinatorTests: readingClause, carbs and forecast body tests. Not run: no build or xcodebuild test in this session; build 235 compiles them only if the test target is built"
met_at = 2026-10-29
met_ts = "2026-10-29T09:50:01+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-8"
text = "A cross-family review (codex-work) passes with no open REAL BUG findings"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "note"
evidence = ".worktrees/carbs-required-actions/.task-relay/notes/20261029-094557-57049-codex-work-review.md"
met_at = 2026-10-29
met_ts = "2026-10-29T09:50:01+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-9"
text = "On build 235 with the toggles on, a Low Glucose Soon (or other glucose alarm) notification shows the current glucose, change per minute and trend word"
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-29

[[sessions]]
host = "claude-code"
ref = "ac19b036-7d7a-477d-abf3-66b10c7bbd8b"
model_family = "claude"
started = 2026-10-29
role = "author"
started_at = "2026-10-29T00:00:00+00:00"
orchestrator = "4837fd6b-a2f8-4921-8c8f-68849deb5bd9"

[[reviews]]
run_id = "cb1e6c93-4108-4f6d-8d0f-c22f35722ffb"
model_family = "codex"
verdict = "pass"
reviewed_commit = "0bc1cdf6b"
reviewed_paths = ["Trio/Sources/Models/GlucoseAlerts/GlucoseAlertConfiguration.swift", "Trio/Sources/Modules/GlucoseAlerts/View/GlucoseAlertsRootView.swift", "Trio/Sources/Services/Alerts/ForecastedGlucoseEvaluator.swift", "Trio/Sources/Services/Alerts/GlucoseAlertCoordinator.swift", "TrioTests/ForecastedGlucoseEvaluatorTests.swift", "TrioTests/GlucoseAlertCoordinatorTests.swift"]
recorded_at = "2026-10-29T00:00:00+00:00"
+++

## Intent

Operator (2026-10-29, after the Low Glucose Soon alert at ~07:55 local): "Trio-092 added the current glucose to the carbs required notification. I want to do the same to the Low Glucose soon notification as well." Then: "yes to both and go ahead and add the similar text changes to the low and urgent low", "also include the same set of changes to the high glucose alert as well", "let's also modify the glucose alarms settings to add toggles to control if the current glucose, the delta, and text description are shown. the ultimate idea being to open this as a PR into upstream dev. so I don't want to dramatically change the code directly, but rather make options available for users." and "the PR scope would include the carbs required changes as well".

Ships in build 235 inside patch 20 (operator: "Fold into patch 20").

## Design (operator answers 2026-10-29)

- Three global toggles on the Glucose Alarms screen (operator: "One global set"), all default OFF (operator: "Off"), so with every toggle off the notification text matches upstream: show current glucose, show change per minute, show trend description.
- Low Glucose Soon checks every forecast point from +5 to +20 min instead of only +20, always on (operator: "I'd think for this one this is an overall improvement to how the process works, not something that users should be able to toggle"), and the body names the first crossing minute. Upstream has no stated design against it: the editor text already says "within the next 20 minutes"; #1428's reporter expected the same; #1547 (open) is a maintainer-acknowledged UX confusion about this alert that the richer body text helps with.

## Upstream research (2026-10-29)

- nightscout/Trio 7a2242bb1 "Drop threshold echo from glucose alarm body text" and aed7308f5 "Rewrite forecasted-low alert copy": upstream moved to short plain copy. This change keeps that copy as the default and reuses its strings.
- #1547: Low Glucose Soon fired with Expected BG 262 and COB on board (min across curves picks the insulin-only curve). dnzxy: "Open to suggestions on how to improve this UX-wise."

## Review history

- 2026-10-29 codex-work gpt-5.6-terra (note `.worktrees/carbs-required-actions/.task-relay/notes/20261029-094557-57049-codex-work-review.md`), reviewed the uncommitted diff later committed as 0bc1cdf6b. Recorded as pass; every finding declined:
  - HIGH, forecast can fire while no reading is fresh: pre-existing upstream behaviour (the forecast path was never gated on reading age), and APSManager does not loop on glucose older than 12 min, so no new determination arrives during a blackout. The reading is only used for the text.
  - MEDIUM, a determination can be evaluated before the newest reading reaches the cache: the cache then holds the previous reading (still under 12 min), so the glucose shown can be one reading behind; nil only right after launch.
  - MEDIUM, new strings not in Localizable.xcstrings: Xcode adds them on an IDE build. To do before the upstream PR, not a build 235 issue.
  - LOW, exact English strings in tests: same convention as the existing tests in the file.

## Upstream PR notes

- Run an Xcode build so the String Catalog picks up: "Notification Content", the three toggle labels, the footer, "%@/min", "Your glucose is already below %@.".
- PR scope per operator: Carbs Required changes (TRIO-092) plus this.
