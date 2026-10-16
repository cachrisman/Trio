+++
uid = "01a1200d-bd52-74bc-b375-949517da3995"
key = "TRIO-072"
title = "Sync dev with upstream 1.0.2.1 (36 commits), resolve scripts/swiftformat.sh exclude-list conflict"
status = "done"
kind = "code"
source = "human"
created = 2026-10-09
updated = 2026-10-16
touched = 2026-10-16
closed = 2026-10-16
first_closed = 2026-10-16
accepted_by = "charlie"
accepted_at = 2026-10-16
accepted_ts = "2026-10-16T21:32:14+02:00"
owner = "me"
tags = ["upstream-sync", "patch-stack"]
files = ["scripts/swiftformat.sh"]
parent = "01a11f7a-4c5b-74fd-b658-3b3095663cd1"

[[acceptance]]
id = "AC-1"
text = "dev contains upstream/dev 1.0.2.1 (fcd5c9a00) and all 12 patches apply on it with patch-audit passing"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-09
evidence_kind = "run"
evidence = "git merge-base --is-ancestor fcd5c9a00 dev: yes (merge 3419c8aa5, then 32ded6428). scripts/repin-g7.sh ran patch-test.sh on 87441ce8a: 12/12 patches applied, patch-audit PASSED (39 warnings, same as build 230), pump-migration sentinel present. Build 231 (build/artifacts/ci-local-build-20261009-090706.log) applied the same 12 patches from 32ded6428."
met_at = 2026-10-09
met_by = "unknown"
met_commit = "32ded642831a1f5c788f043be392137cc245dd2a"

[[acceptance]]
id = "AC-2"
text = "dev pushed to origin"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-10-09
evidence_kind = "operator"
evidence = "Operator ran 'git push origin dev' in this session on 2026-10-09; origin/dev = dev = 32ded6428 (checked with git fetch)."
met_at = 2026-10-09
met_by = "Charlie Chrisman"
met_commit = "32ded642831a1f5c788f043be392137cc245dd2a"

[[sessions]]
host = "claude-code"
ref = "a856db00-b8b7-4312-90dc-4bd1a571b850"
model_family = "claude"
started = 2026-10-09
role = "author"
started_at = "2026-10-09T09:46:01+00:00"

[[reviews]]
run_id = "3fff7de9-1227-4f72-875a-094fb22bf722"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "826bf8a237728603cd1e70ecb44f541ee36ab7d1"
reviewed_paths = ["scripts/swiftformat.sh"]
recorded_at = "2026-10-16T00:00:00+00:00"
+++

## Intent

Operator instruction 2026-10-08: merge the latest `upstream/dev` into `dev` for build 231. Track upstream/dev, not the `v1.0.2` release tag: the app version comes from the project files on dev.

## Steps
- Merged `upstream/dev` fcd5c9a00 (APP_VERSION 1.0.2, APP_DEV_VERSION 1.0.2.1; 36 non-merge commits since build 230's 1.0.1.5 base) into `dev` as 3419c8aa5. One conflict, `scripts/swiftformat.sh` exclude list: kept dev's build/DerivedData/worktree/SourcePackages/`*.pb.swift` excludes and quoting fixes, took upstream's LibreCRKit to RoundWhiteDiscKit swap and its new EversenseKit exclude.
- 32ded6428 merges origin/dev's GH Action upstream-sync commit 1b9fa08c3, with no tree change. The operator pushed `dev` (origin/dev = 32ded6428).
- Verification before the build: a dry run on a scratch branch applied all 12 patches on the merged base, with a deletion review of the four files that both upstream and the patch stack touch (TrioSettings, PluginSource, NightscoutManager, SettingItems): no upstream lines lost. Upstream's diff touches no watch, complication, ContactImage or WatchConfig path. `patch-test.sh`: 12/12 applied, patch-audit PASSED (39 warnings, same as build 230), pump-migration sentinel present.

## What upstream brought
- CGM data to Nightscout: sensor problems upload as notes; new "Upload CGM Sensor States" setting (off by default, with help text, in settings search); sensor states without a reliable reading use the CGM driver's own state names.
- Calibrations stored as manual fingersticks; manual glucose entries to Nightscout fixed.
- Treatments view auto-scrolling and related fixes.
- Two crash risks fixed in the override preset list; Y-axis grid toggle spacing fixed in UI settings.
- Accu-Chek and Eversense: more CGM detail (Accu-Chek warmup end and expiry); both drivers updated.
- Libre: LibreCRKit replaced by RoundWhiteDiscKit; LibreLoop updated (new settings title; minute-by-minute forwarding toggle hidden).
- Housekeeping: script and submodule updates (#1612), swiftformat pass, extracted strings.

## Release note

Trio 1.0.2 from upstream: sensor problems and (optionally) CGM sensor states upload to Nightscout, calibrations are stored as fingersticks, the treatments list scrolls itself, two crashes in the override presets list are fixed, Accu-Chek and Eversense show more sensor detail, and Libre users get the new RoundWhiteDiscKit driver.

Shipped in build 231 (TRIO-071).
