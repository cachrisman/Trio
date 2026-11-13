+++
uid = "01a1bae6-8121-72e2-baf4-ae62463c043a"
key = "TRIO-104"
title = "Mac crash-report pipeline: pull Trio .ips off the iPhone, symbolicate with release dSYMs, ingest to BetterStack hourly"
status = "done"
kind = "code"
source = "human"
created = 2026-11-08
updated = 2026-11-08
touched = 2026-11-08
closed = 2026-11-08
first_closed = 2026-11-08
accepted_by = "charlie"
accepted_at = 2026-11-08
accepted_ts = "2026-11-08T20:21:48+01:00"
tags = ["watch", "crash", "betterstack", "tooling"]
files = ["scripts/trio-crash-ingest.py", "scripts/tests/test_trio_crash_ingest.py"]
priority = 2

[[acceptance]]
id = "AC-1"
text = "scripts/trio-crash-ingest.py parses .ips (header + body JSON), keeps only Trio crash reports (bug_type 309, Trio / Trio Watch App / extensions), and builds one event per crash with dt=captureTime (UTC), app, build, OS, model, exception type/signal/codes, termination indicator/reasons, faulting queue, seconds_since_launch, symbolicated faulting-thread frames and top app frames"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "commit"
evidence = "cb42d9fa4 parse_ips/is_trio_crash/build_event unchanged by the --status-event change; 70 unit tests OK (python3 -I -m unittest discover -s scripts/tests); live launchd run parsed 241 staged reports (239 Trio crashes, all symbolicated)"
met_at = 2026-11-08
met_ts = "2026-11-08T20:19:24+01:00"
met_by = "claude-code"
met_commit = "cb42d9fa46a907f1d2241559cc53247dbb8a3e5c"

[[acceptance]]
id = "AC-2"
text = "Symbolication uses the release dSYM matched by image UUID (downloaded once per build into a cache); a missing release falls back to unsymbolicated image+offset frames with symbolicated=false"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "run"
evidence = "0099ae618 live ingest 2026-11-08: 239/239 crash events symbolicated by dSYM UUID (builds 235-237 localCI); MISSING fallback and 24h no-asset deferral covered by unit tests"
met_at = 2026-11-08
met_ts = "2026-11-08T15:12:10+01:00"
met_by = "claude-code"
met_commit = "0099ae618b4b4336ad924c3ed82faee8a401cc51"

[[acceptance]]
id = "AC-3"
text = "Device pull uses Apple's xcrun devicectl, read-only (list devices, device info files, device copy from; never deletes reports), finds the paired physical iPhone over USB or the local network, works when run by launchd, and an unreachable device is a logged no-op, not an error"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "run"
evidence = "0099ae618 launchd runs 5-6 (org.trio.crash-ingest): 'devicectl device=00008150-001218C63C87801C listed=239 new=0 copy_failed=0', device=ok, exit 0; only list devices / device info files / device copy from are invoked (tests assert no delete/remove verbs); no device -> unreachable exit 0"
met_at = 2026-11-08
met_ts = "2026-11-08T15:12:10+01:00"
met_by = "claude-code"
met_commit = "0099ae618b4b4336ad924c3ed82faee8a401cc51"

[[acceptance]]
id = "AC-4"
text = "Events post to BetterStack over HTTPS with the token read from the login Keychain; incident ids are recorded as sent only after a 2xx, so reruns never duplicate; --dry-run posts nothing and writes no state; the token is never logged"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "run"
evidence = "0099ae618 live ingest: 239 events posted to s1659391.eu-central-1a.betterstackdata.com (host allowlisted, token from Keychain), sent.json holds 239 ids; BetterStack query shows 239 crash_report rows 2026-11-02..11-08; rerun sent 0 (duplicate=239); codex review over c5e0b60d8..0099ae618 PASSED (e5959780)"
met_at = 2026-11-08
met_ts = "2026-11-08T15:12:10+01:00"
met_by = "claude-code"
met_commit = "0099ae618b4b4336ad924c3ed82faee8a401cc51"

[[acceptance]]
id = "AC-5"
text = "Unit tests in scripts/tests/test_trio_crash_ingest.py pass, using synthetic fixtures only (no real crash reports committed)"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "run"
evidence = "0099ae618: python3 -I -m unittest discover -s scripts/tests -> 64 tests OK; synthetic fixtures only"
met_at = 2026-11-08
met_ts = "2026-11-08T15:12:10+01:00"
met_by = "claude-code"
met_commit = "0099ae618b4b4336ad924c3ed82faee8a401cc51"

[[acceptance]]
id = "AC-6"
text = "Dry run over the 18 operator-shared reports yields 17 unique crash events with the TRIO-103 assumeIsolated <- ExtensionDelegate.handle(_:) frames symbolicated"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "run"
evidence = "6f30c2bce dry run --no-device --from <18 shared .ips>: files=18 duplicate=1 new=17 unsymbolicated=0; 16 EXC_BREAKPOINT on bluetoothManagerQueue with top='MainActor.assumeIsolated < ExtensionDelegate.handle(_:) (ExtensionDelegate.swift:83)', 1 EXC_CRASH HealthKit watchdog"
met_at = 2026-11-08
met_ts = "2026-11-08T12:35:03+01:00"
met_by = "claude-code"
met_commit = "6f30c2bce09847c27d2578cb66642939afa645ba"

[[acceptance]]
id = "AC-7"
text = "Live: launchd agent installed and loaded; after the iPhone is reachable, crash_report events from the device appear in BetterStack"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "operator"
evidence = "Operator in chat 2026-11-08: 'Mark TRIO-104 AC-7 as met for me.' Basis: launchd agent org.trio.crash-ingest installed and loaded (hourly, devicectl pull works with the phone locked); 239 crash_report rows from the device in BetterStack; launchd upload proven by a crash_ingest_run status row at 2026-11-08 19:12:37 UTC (cb42d9fa4, --status-event)"
met_at = 2026-11-08
met_ts = "2026-11-08T20:18:27+01:00"
met_by = "charlie"
met_commit = "cb42d9fa46a907f1d2241559cc53247dbb8a3e5c"

[[sessions]]
host = "claude-code"
ref = "6f875a0e-dcaf-4974-99b5-794b195bc49c"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T11:26:50+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "c9451fa6-68da-4dfc-8f23-e06a270998a6"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T11:31:58+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "20261108-123500-direct-6f30c2bc"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T11:35:01+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "20261108-124000-direct-11236322"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T11:38:04+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "3d0a27a4-2d76-4e33-9164-9f3ef76326b7"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T11:41:38+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "20261108-124300-direct-05b19aa7"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T11:42:12+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "7cdad2fc-9ee3-4258-9340-8ae9d3536706"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T11:46:46+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "1d04b4ec-2842-437c-b159-ee5bdb8deed5"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T11:49:44+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "3911cfe6-5120-4663-93e2-79363039e5c7"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T11:53:32+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "cd4f77b6-510a-4f25-a2e7-ad3e9ed9ee54"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T14:03:43+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "a2cea999-cd55-43c3-aae7-fa1c6b3e5f88"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T14:08:38+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[sessions]]
host = "claude-code"
ref = "c96e96f9-3857-4c80-b1a0-cf94fb1b5b02"
model_family = "claude"
started = 2026-11-08
role = "author"
started_at = "2026-11-08T19:10:52+00:00"
orchestrator = "52b0f7e0-ce9b-49a6-b77d-8455c5db1cf8"

[[reviews]]
run_id = "5b743d10-44cb-4b72-81b0-98b8174c5eda"
model_family = "codex"
verdict = "fail"
reviewed_commit = "c5e0b60d8dae6e5a5eb5d167b6d7768141d90fe4"
reviewed_paths = ["scripts/trio-crash-ingest.py", "scripts/tests/test_trio_crash_ingest.py", "scripts/launchd/org.trio.crash-ingest.plist"]
recorded_at = "2026-11-08T11:30:37+00:00"

[[reviews]]
run_id = "fdffb708-8127-438c-afa3-15073dccfb8e"
model_family = "codex"
verdict = "fail"
reviewed_commit = "6f30c2bce09847c27d2578cb66642939afa645ba"
reviewed_paths = ["scripts/launchd/org.trio.crash-ingest.plist", "scripts/tests/test_trio_crash_ingest.py", "scripts/trio-crash-ingest.py"]
recorded_at = "2026-11-08T11:38:03+00:00"

[[reviews]]
run_id = "c06fec6a-cf57-4e80-93f5-6beea10143b9"
model_family = "codex"
verdict = "fail"
reviewed_commit = "112363220358aba53b6c7bd27ed305a587eb8176"
recorded_at = "2026-11-08T11:40:42+00:00"

[[reviews]]
run_id = "1f0d90ad-86c2-45bb-8e6b-8155aeb09be9"
model_family = "codex"
verdict = "fail"
reviewed_commit = "05b19aa76c20a8c99a6b5d4261d756477a399627"
recorded_at = "2026-11-08T11:44:15+00:00"

[[reviews]]
run_id = "1ef785d1-34a7-4a16-a478-64b4cf677a4c"
model_family = "codex"
verdict = "fail"
reviewed_commit = "ebdac4d3178a91c7197c884a9eedd7116dbc500f"
recorded_at = "2026-11-08T11:49:45+00:00"

[[reviews]]
run_id = "49ae39d8-faeb-4111-9883-05c0d2b7012f"
model_family = "codex"
verdict = "fail"
reviewed_commit = "942bf0186c0867a78f6220706db08f3a1c48ca2a"
recorded_at = "2026-11-08T11:53:33+00:00"

[[reviews]]
run_id = "095d57c6-b3e4-4d1c-8eaa-546a77634704"
model_family = "codex"
verdict = "pass"
reviewed_commit = "d205ae5694f2d928d17ebed8900644de798177c5"
recorded_at = "2026-11-08T11:55:15+00:00"

[[reviews]]
run_id = "71314e75-9b79-48fa-b98c-77883eefc960"
model_family = "codex"
verdict = "fail"
reviewed_commit = "2ffbdfae00ef6b04a9d50d5f1dc5e04b31f6c40d"
recorded_at = "2026-11-08T14:07:57+00:00"

[[reviews]]
run_id = "e5959780-8041-4af2-99a8-f6ec6a4dbf06"
model_family = "codex"
verdict = "pass"
reviewed_commit = "0099ae618b4b4336ad924c3ed82faee8a401cc51"
recorded_at = "2026-11-08T14:12:08+00:00"

[[reviews]]
run_id = "5841f8f1-a246-4d2a-8ac5-25a3eb5af2a7"
model_family = "codex"
verdict = "pass"
reviewed_commit = "0099ae618b4b4336ad924c3ed82faee8a401cc51"
reviewed_paths = ["scripts/trio-crash-ingest.py", "scripts/tests/test_trio_crash_ingest.py"]
recorded_at = "2026-11-08T19:12:21+00:00"
+++

## Intent

Watch (and phone) crash reports only exist as `.ips` files on the iPhone (Settings → Privacy & Security → Analytics Data); no app can read them and MetricKit is unavailable on watchOS (verified in the SDK headers, `API_UNAVAILABLE(tvos, watchos)`). Finding the TRIO-103 SIGTRAP needed the operator to share 18 reports by hand out of 200+.

Build a Mac-side pipeline in Trio-dev: `scripts/trio-crash-ingest.py` (Python 3 stdlib) pulls Trio crash reports off the paired iPhone with `idevicecrashreport -k` (copy, never remove from the device), also accepts folders of `.ips`, symbolicates the faulting thread with the matching build's `Trio.app.dSYM.zip` from the GitHub release `trio-v<ver>-<build>-localCI`, and posts one structured event per crash to BetterStack's HTTP ingest, deduplicated by incident id. A launchd agent runs it hourly. The BetterStack token lives in the login Keychain, entered by the operator; the script never prints it.

Operator asked 2026-11-08: "Let's build the Mac pipeline".
