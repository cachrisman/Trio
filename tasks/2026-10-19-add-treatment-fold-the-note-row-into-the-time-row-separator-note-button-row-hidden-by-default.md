+++
uid = "01a1558c-e118-71e2-90f0-dcd910b90013"
key = "TRIO-085"
title = "Add-treatment: fold the note row into the time row (separator + note button, row hidden by default)"
status = "review"
kind = "code"
source = "human"
created = 2026-10-19
updated = 2026-10-19
touched = 2026-10-19
tags = ["treatments", "ui"]
files = ["Trio/Sources/Modules/Treatments/View/TreatmentsRootView.swift"]
parent = "01a15580-dcde-70fd-902f-5bcb7d48cb9f"
priority = 3

[[acceptance]]
id = "AC-1"
text = "Time row ends with a vertical Divider then a note button; the Note row is hidden while the note is empty and not toggled open; tapping the button reveals it with the text field focused; a non-empty note keeps the row shown; diff limited to TreatmentsRootView.swift"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "commit"
evidence = "900962668 — Divider + note button after the time control, row shown when toggled or note non-empty, auto-focus on reveal; only TreatmentsRootView.swift; patch 16 regenerated, patch-test PASSED; codex-work review PASS 00d44379"
met_at = 2026-10-19
met_ts = "2026-10-19T21:39:27+02:00"
met_by = "claude-code"
met_commit = "041223aa485371f76a2927666a66891781786dca"

[[acceptance]]
id = "AC-2"
text = "On device the time row, separator and note button look right and the note row opens/closes as expected"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-19
evidence_kind = "operator"
evidence = "Operator on build 233, 2026-10-19 (chat): 'Generally looks pretty good'; the vertical separator between the time and the note button 'is much fainter than the horizontal lines ... but not really a big deal'; 'The note row opens and closes properly. Tapping on the note button makes it show up and makes it go away.'"
met_at = 2026-10-19
met_ts = "2026-10-19T23:13:11+02:00"
met_by = "charlie"
met_commit = "e57a4a8f1961329c6f96633a364d45d6b05762b2"

[[sessions]]
host = "claude-code"
ref = "0fb6d334-7441-48a6-9bdf-3d1c5fc524b7"
model_family = "claude"
started = 2026-10-19
role = "author"
started_at = "2026-10-19T19:22:04+00:00"

[[reviews]]
run_id = "00d44379-9df2-4dbc-8a4a-87fd05c4d0db"
model_family = "codex"
verdict = "pass"
reviewed_commit = "90309970014babedf55394626144e4fb882dd338"
reviewed_paths = ["Trio/Sources/Modules/Treatments/View/TreatmentsRootView.swift"]
recorded_at = "2026-10-19T19:31:48+00:00"
+++

## Intent

## Design (operator-approved 2026-10-19, mockup treatments-time-note-mockup.svg)

The note row on the add-treatment screen is hidden by default. The time row becomes `[clock] … Now | [note+]`: the existing right-aligned time value ("Now" or the DatePicker with -/+), then a vertical hairline separator matching the list row separators, then a note button (`note.text.badge.plus`-style, accent colour). Tapping it reveals the existing `TextFieldWithToolBarString` note row below; the icon shows a filled state while the row is open. The row is shown automatically when `state.note` is non-empty.

## Open choices (defaults chosen unless operator says otherwise)

- Auto-focus the note field on reveal: yes.
- Tapping the button again with an empty note hides the row; a non-empty note keeps it shown.
- Same file as patch 16 (`TreatmentsRootView.swift`): build on `feature/treatments-bolus-mode` and fold into patch 16 rather than a separate overlapping patch.


## Release note

When adding a treatment, the note field is now hidden behind a note button at the end of the time row. Tap it to open the note field. A treatment that already has a note shows the field straight away.


Shipped in build 233 (TRIO-083), uploaded to TestFlight 2026-10-19 22:55.
