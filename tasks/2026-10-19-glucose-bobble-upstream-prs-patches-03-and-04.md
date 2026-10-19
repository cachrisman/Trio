+++
uid = "01a155c1-85b6-7660-98f0-1b27baa9f8c4"
key = "TRIO-091"
title = "Glucose Bobble upstream PRs (patches 03 and 04)"
status = "backlog"
kind = "code"
source = "agent-discovered"
source_ref = "019f8141-e117-77db-9216-aacaa57468d7#AC-5"
created = 2026-10-19
updated = 2026-10-19
touched = 2026-10-19
tags = ["upstream", "glucose-bobble"]
parent = "019f8141-e117-77db-9216-aacaa57468d7"

[[acceptance]]
id = "AC-1"
text = "Glucose Bobble circular complication PRs, moved from TRIO-063 (2026-09-24): upstream PR branches for patches 03 (shareable Glucose Bobble view: inside-ring arrow placement, solid ring colour) and 04 (circular complication, phone settings, watch-state fields), each cut from upstream/dev and containing only that patch's changes, with Xcode target membership in project.pbxproj for the new files: GlucoseBobbleComplicationSettings.swift (phone, watch app, complication), GlucoseBobbleComplicationSettingsView.swift (phone), GlucoseComplicationSnapshot.swift (watch app, complication), GlucoseBobbleContactView.swift and Triangle.swift (complication), plus the watch targets' App Group entitlements and AppGroupID build settings. The patches apply cleanly to upstream/dev, so the PR diffs are the patch diffs. project.pbxproj edits are the operator's."
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-10-19
moved_from = "019f8141-e117-77db-9216-aacaa57468d7#AC-5"
+++

Moved from TRIO-021 AC-5: Glucose Bobble circular complication PRs, moved from TRIO-063 (2026-09-24): upstream PR branches for patches 03 (shareable Glucose Bobble view: inside-ring arrow placement, solid ring colour) and 04 (circular complication, phone settings, watch-state fields), each cut from upstream/dev and containing only that patch's changes, with Xcode target membership in project.pbxproj for the new files: GlucoseBobbleComplicationSettings.swift (phone, watch app, complication), GlucoseBobbleComplicationSettingsView.swift (phone), GlucoseComplicationSnapshot.swift (watch app, complication), GlucoseBobbleContactView.swift and Triangle.swift (complication), plus the watch targets' App Group entitlements and AppGroupID build settings. The patches apply cleanly to upstream/dev, so the PR diffs are the patch diffs. project.pbxproj edits are the operator's.

Reason: TRIO-021 becomes a project (operator, 2026-10-19); one task per upstream PR


## Intent

Upstream PR branches for patches 03 (shareable Glucose Bobble view) and 04 (circular complication), each cut from upstream/dev with only that patch's changes. These don't depend on the G7SensorKit chain. The project.pbxproj target-membership edits are the operator's, so the AC is operator-owned. It was first moved here from TRIO-063 on 2026-09-24, and is now part of the TRIO-021 project.
