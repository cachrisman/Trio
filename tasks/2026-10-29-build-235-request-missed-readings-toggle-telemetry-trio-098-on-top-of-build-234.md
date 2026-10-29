+++
uid = "01a18629-b536-77bb-880c-bb88484be460"
key = "TRIO-098"
title = "Build 235: Request Missed Readings toggle telemetry (TRIO-099) on top of build 234"
status = "open"
kind = "project"
source = "human"
created = 2026-10-29
updated = 2026-10-29
touched = 2026-10-29
tags = ["build", "testflight"]

[[acceptance]]
id = "AC-1"
text = "Patch 02 repinned to the new fork commit and scripts/patch-test.sh clean (patch-audit PASS, sentinel present)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-10-29
evidence_kind = "run"
evidence = "./scripts/repin-g7.sh 2026-10-29: patch 02 pin 7fa073c -> 0b10d556d (TRIO-099, on origin/main); patch-test.sh: all 17 patches applied, patch-audit PASSED (49 warnings, pump-migration sentinel present). Patch 02 uncommitted for the operator."
met_at = 2026-10-29
met_ts = "2026-10-29T06:48:41+01:00"
met_by = "claude-code"
met_commit = "6737274a9e432e76599fc24e2fe2c52775391092"

[[acceptance]]
id = "AC-2"
text = "Build uploaded to TestFlight and release recorded (ci/local-build.sh --task TRIO-098)"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-10-29

[[acceptance]]
id = "AC-3"
text = "Installed on the operator's phone and watch; G7 readings flowing on build 235 in BetterStack"
owner = "operator"
phase = "post-deploy"
state = "open"
added_at = 2026-10-29

[[decisions]]
id = "D-1"
question = "Should Carbs Required's glucose clause follow the new Show current glucose toggle (off by default, so build 234's always-on clause needs the toggle turned on)?"
default = "Yes, follow the toggle"
options = ["Yes, follow the toggle", "No, always show it"]
deadline = 2026-10-29
state = "open"
raised_at = 2026-10-29
raised_by = "claude-code"
shadow = true
hard = false
hard_rules = []

[[decisions]]
id = "D-2"
question = "Low Glucose Soon whole-window check: option or always on?"
default = "Option, default off"
options = ["Option, default off", "Always on"]
deadline = 2026-10-29
state = "resolved"
raised_at = 2026-10-29
raised_by = "claude-code"
shadow = true
hard = false
hard_rules = []
chosen = "Always on"
outcome = "differed"
resolved_at = 2026-10-29

[[decisions]]
id = "D-3"
question = "Default for the new notification-content toggles"
default = "Off"
options = ["Off", "On"]
deadline = 2026-10-29
state = "resolved"
raised_at = 2026-10-29
raised_by = "claude-code"
shadow = true
hard = false
hard_rules = []
chosen = "Off"
outcome = "matched"
resolved_at = 2026-10-29

[[decisions]]
id = "D-4"
question = "Where the notification-content toggles live"
default = "One global set"
options = ["One global set", "Per alarm"]
deadline = 2026-10-29
state = "resolved"
raised_at = 2026-10-29
raised_by = "claude-code"
shadow = true
hard = false
hard_rules = []
chosen = "One global set"
outcome = "matched"
resolved_at = 2026-10-29

[[decisions]]
id = "D-5"
question = "Patch placement for the alert-text work"
default = "New patch 21"
options = ["New patch 21", "Fold into patch 20"]
deadline = 2026-10-29
state = "resolved"
raised_at = 2026-10-29
raised_by = "claude-code"
shadow = true
hard = false
hard_rules = []
chosen = "Fold into patch 20"
outcome = "differed"
resolved_at = 2026-10-29
+++

## Intent

Build 234 shipped the Request Missed Readings toggle (TRIO-094) without logging its state, so the on/off test windows (TRIO-094 AC-8/AC-9) can't be told apart from telemetry alone. Build 235 is build 234 plus that logging fix (TRIO-099), nothing else, so the on/off comparison isn't confounded by other changes. The upstream sync moves to build 236.

Operator, 2026-10-29: "I'm of the opinion that we need to fix this and rebuild and deploy again. Do a build 235."


## Attempt 2026-10-29 06:48 local

- Command: `./ci/local-build.sh --include-untracked --no-sync-upstream --task TRIO-098`
- Log: `build/artifacts/ci-local-build-20261029-064859.log`
- Base ref: `dev`
- dev: `6737274a9`
- upstream/dev: `568afd482`
- Xcode: Xcode 27.1


- Outcome: FAILED (exit 1) (ended 2026-10-29 06:53)
- Failed stage: Build IPA
- Last errors:

```
bundler: failed to load command: fastlane (/opt/homebrew/lib/ruby/gems/4.0.0/bin/fastlane)
[build] ❌ Build step FAILED (exit code: 1)
[stage] ✗ Failed: Build IPA (1m 35s)
```

## Attempt 2026-10-29 06:48 local

Failed after 4m 55s, at Build IPA (log `build/artifacts/ci-local-build-20261029-064859.log`). Every App Store Connect call returned `Spaceship::AccessForbiddenError`: "PLA Update available … your team's Account Holder … must agree to the latest Program License Agreement." The certs lanes failed (non-fatal), then provisioning lookup in the IPA build failed the same way. Nothing was uploaded, tagged or released. The failed worktree is preserved at `../.trio-worktrees/ci-build-20261029-064901`. Rerun once the operator has accepted the agreement.


## Attempt 2026-10-29 09:49 local

- Command: `./ci/local-build.sh --include-untracked --no-sync-upstream --task TRIO-098`
- Log: `build/artifacts/ci-local-build-20261029-094923.log`
- Base ref: `dev`
- dev: `6737274a9`
- upstream/dev: `e24d2de97`
- Xcode: Xcode 27.1


- Outcome: success (ended 2026-10-29 10:06)
- Build number: 235
- TestFlight: uploaded at 10:00:05
- Public release: https://github.com/cachrisman/Trio/releases/tag/trio-v1.0.2-235-localCI
- Private backup release (draft): https://github.com/cachrisman/trio-builds-private/releases/tag/trio-v1.0.2-235-localCI

| Stage | Duration |
|---|---|
| Environment & Tool Validation | 0s |
| Worktree Setup | 20s |
| Certificates & Config | 8s |
| Patch Application | 4s |
| Ruby Dependencies | 0s |
| Build IPA | 8m 6s |
| TestFlight Upload | 8m 13s |
| Record Release | 28s |
| TOTAL (Success) | 17m 20s |
