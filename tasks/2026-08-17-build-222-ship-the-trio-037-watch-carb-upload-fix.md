+++
uid = "01a00f08-4dba-736c-b956-cf36813a25af"
key = "TRIO-044"
title = "Build 222: watch carb upload, delta correctness, durable ACK, and G7 state telemetry"
status = "ready"
kind = "code"
source = "human"
created = 2026-08-17
updated = 2026-09-26
touched = 2026-09-26
owner = "me"
tags = ["build", "testflight", "release"]

[[acceptance]]
id = "AC-1"
text = "All five fixes committed on their feature branches and patches 05, 09, 10 regenerated via `mid-stack-update.sh` — never hand-edited"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-2"
text = "`./scripts/patch-test.sh` passes, including the deletion-footprint audit"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-3"
text = "Full diff vs base reviewed for every regenerated patch, **deletions especially** — the class of review that would have caught TRIO-037 before it shipped"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-4"
text = "Stacked verification: all patches applied to a scratch tree off `dev`, with per-fix assertions counted in the stacked result rather than in any patch alone"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-5"
text = "Diverse-family review recorded against the **final** state of each changed patch"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-6"
text = "Operator authorization to build — builds and TestFlight are explicit-request only per AGENTS.md; this task existing is not that authorization"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-7"
text = "`./ci/local-build.sh --include-untracked` completes and uploads to TestFlight"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-8"
text = "Build number recorded here once known"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-9"
text = "Better Stack shows build 222 rows on both `ios` and `watchos` within minutes of upload, matching how 221 was confirmed"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-10"
text = "**TRIO-037 verified in production**: a carb entered on the watch reaches HealthKit and Tidepool. The original reason for the build; must not be skipped because it needs a manual action"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-11"
text = "**TRIO-038 / TRIO-045 verified**: watch delta matches the phone in mmol/L, and a delta following a disconnect-and-backfill reflects the last 5-minute step rather than the whole gap"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-12"
text = "**TRIO-041 verified**: a real state-18 event emits the mapped name on `watchos`"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-13"
text = "**TRIO-043 verified**: watch error/log payloads still ACK and appear phone-side; no regression in round-trip behaviour"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-14"
text = "Decide whether historical watch carbs stored with NULL flags should be backfilled — TRIO-037 carries this as an open decision, and shipping the fix does not resolve it"
owner = "agent"
phase = "pre-review"
state = "dropped"
added_at = 2026-09-26
reason = "superseded by list '## Acceptance criteria'"
closed_at = 2026-09-26

[[acceptance]]
id = "AC-15"
text = "`./ci/local-build.sh --include-untracked` completes and uploads to TestFlight"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-16"
text = "Build number recorded — `trio-v0.8.4-222`, branch `origin/ci-build/trio-v0.8.4-222-localCI-20260819T225258Z`"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-17"
text = "Better Stack shows build 222 on both `ios` and `watchos` within minutes of install"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"

[[acceptance]]
id = "AC-18"
text = "**TRIO-037 verified in production**: a carb entered on the watch reaches HealthKit and Tidepool — the reason for the build; still needs a manual action"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-19"
text = "**TRIO-038 / TRIO-045 verified**: mmol/L delta matches the phone, and a delta after a disconnect-and-backfill reflects the last 5-minute step rather than the whole gap"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-20"
text = "**TRIO-041 verified**: a real state-18 event emits the mapped name on `watchos`"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-21"
text = "**TRIO-043 verified**: watch error/log payloads still ACK and arrive phone-side"
owner = "agent"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[acceptance]]
id = "AC-22"
text = "Historical watch carbs with NULL flags — **operator decided 2026-08-20 not to backfill**; recorded on TRIO-037"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "legacy"
evidence = "migrated from a ticked checkbox"
met_at = 2026-09-26
met_by = "migration"
+++

## Intent

Ship the five fixes below. The build was originally opened for TRIO-037 alone — a live data-loss
defect in build 221 — and grew into a substantive release once the surrounding work turned out to be
low-risk and to sit on clean feature branches.

Baseline: `dev` at `125424e99` (build 221, shipped 2026-08-16 22:13 CEST).

## What build 222 includes

| # | Item | Task | Patch | Change |
|---|---|---|---|---|
| 1 | Watch carbs never reach HealthKit / Tidepool | TRIO-037 | 05 | Patch stops deleting `isUploadedToHealth` / `isUploadedToTidepool` at both watch carb-entry sites |
| 2 | mmol/L delta parity, watch vs phone | TRIO-038 | 10 | Round each operand before subtracting, matching the phone |
| 3 | Watch `egv_unreliable` mapped state name | TRIO-041 | 09 | Three sites emit `algorithm_state=<case name>` + `algorithm_state_raw=<Int>` |
| 4 | Watch delta spans the whole gap | TRIO-045 | 09 | Delta baseline comes from `WatchGlucoseHistoryStore`, so backfill readings count |
| 5 | Phone ACKs watch payloads before handling is durable | TRIO-043 | 05 | Handling now precedes both the dedupe record and the ACK |

Items 1 and 2 fix data loss and a wrong number on screen. Items 3–5 are correctness and observability
work that became cheap to include.

### Why no branch rebuild was needed

TRIO-046 is **not** a prerequisite. Every patch touched here — 05, 09, 10 — sits on a feature
branch the orphan survey found clean (patch 10 was rebuilt on 2026-08-17). The two stale branches,
`feature/cloud-logging` (patch 06) and `feature/phone-ble-observer-telemetry` (patch 13), are only
reached by TRIO-039 / TRIO-040, which are deliberately not in this build.

### Deliberately excluded

| Candidate | Task | Why not |
|---|---|---|
| `clearSavedContextForPayload` ignores its `payloadId` | TRIO-042 (2nd half) | **Open decision.** `saveCrashContext` has zero callers anywhere in the stack, so `crashContextKey` is never written and the clear is a no-op on absent keys. There is no payload→context association to scope to; honouring the parameter means inventing one in unreachable code |
| `WatchErrorReporter` replay consumer | TRIO-042 (1st half) | Needs a consumer designed and payloads persisted; not a bounded edit |
| CloudLogUploader durable-4xx stall | TRIO-039 | Needs a data-discard policy decision, and patch 06's branch is stale |
| CloudLogUploader multiline split | TRIO-040 | Offset arithmetic, where two bugs have already landed; not to be rushed |
| G7 backfill follow-ons | TRIO-036 | Investigation, produces no shippable code |

### Carried forward unchanged from 221

Already in `dev`, simply rebuilt: G7SensorKit pinned at `50c76a7` (TRIO-028 batched-backfill
parser, TRIO-033 shape sampling, TRIO-034 `egv_unreliable`); patch 06 cloud logging with
TRIO-032's offset keying; patch 09 with TRIO-029 watch backfill storage.



## Notes carried over from acceptance criteria
## Note on what 221 telemetry says

221 is healthy: 11 h unbroken logging on both platforms, the only errors a pre-existing benign
`settings/model.json` lookup, TRIO-029 and TRIO-032 both confirmed working in production. The
case for 222 is TRIO-037's ongoing data loss, not instability in 221.

## Build attempt 2026-08-18 — FAILED on a local firewall block, not on the code

`./ci/local-build.sh --include-untracked`, run at 08:43. Failed after 1 h 18 m.

| Stage | Result |
|---|---|
| Environment, worktree | ✅ |
| Certificates & Config | ⚠️ **51 m 43 s** — repeated `Net::OpenTimeout` to `api.appstoreconnect.apple.com` |
| Patch Application | ✅ 2 s |
| Build IPA | ❌ 26 m 4 s — same timeout, in `Spaceship::ConnectAPI::TestFlight::API#get_apps` |

**Nothing shipped and nothing escaped:** zero compilation reached, no `ci-build/*` branch pushed (newest
remote ref is still 221 from 2026-08-16), no TestFlight upload, no GitHub release, `dev` unchanged.

### Root cause: Little Snitch blocks Homebrew's ruby

Isolated at the TCP level:

| Binary | Result |
|---|---|
| `curl` (Apple-notarized) | connects in **0.3 ms**, HTTP 401 as expected |
| `/opt/homebrew/bin/ruby` | **`Errno::ETIMEDOUT`** to 17.56.10.18:443 |

The network is fine. Build 221 (2026-08-16) completed its Certificates & Config stage in **7 seconds**
with zero timeouts, so the grant that permitted ruby then was time-limited and has lapsed. **Expect
this to recur after every Little Snitch restart** unless the rule is made permanent — worth fixing as
a rule, not another one-off approval.

Ruby was **not** upgraded since 221 (`/opt/homebrew/bin/ruby` symlink dates from Jul 16), so a
changed binary path is not the cause.

### It cannot be fixed over SSH

`littlesnitch` exists at `/Applications/Little Snitch.app/Contents/Components/littlesnitch`, but every
useful subcommand needs root **and** the tool is fenced behind a GUI toggle. Verified 2026-08-18 with
`sudo littlesnitch export-model`, which returned:

```
Error: command line tool is not authorized to make changes.
Please enable access in Little Snitch.app > Preferences > Security.
```

So the export → edit → `restore-model` route is unavailable. Deploy requires physical access.

## Compile verification — the one thing that WAS closed

Since `xcodebuild` is Apple-signed and unaffected by the firewall, both targets were built from the
preserved worktree (all nine patches applied) with signing disabled:

| Target | Result |
|---|---|
| `Trio Watch App` (watchOS, arm64_32 + arm64) | ✅ **BUILD SUCCEEDED** |
| `Trio` (iOS) | ✅ **BUILD SUCCEEDED** |

Zero errors, no warnings in either changed file. Real products emitted (`Trio Watch App.app`,
`Trio.app`), not an incremental no-op.

This matters because none of this session's Swift had ever been through a compiler, and TRIO-043
moved a `replyHandler` closure across a scope boundary in three separate files — the shape of edit
that produces a capture or scoping error static review cannot catch. It does not.

**Caveat, per AGENTS.md rule 12: a passing compile is not behavioural verification.** It proves the
code builds, nothing more. The production criteria below remain open.

First attempt at this used `-project Trio.xcodeproj` and failed with
`Unable to resolve module dependency: 'G7SensorKit'` — an invocation error, not a code defect. The
submodule frameworks are wired through `Trio.xcworkspace`; submodules were correctly initialised
(G7SensorKit at `50c76a71`, the pin 221 shipped).

## State when the deploy can be retried

`dev` at `02ec6ada3`. `patch-test.sh` green, drift CLEAN, ten stacked assertions passing, all five
tasks carrying diverse codex `pass` reviews **against final patch states**. Nothing further is needed
except the firewall.

Preserved worktree left in place at `.trio-worktrees/ci-build-20260818-084348` (it is what the compile
check ran in); remove with `git worktree remove --force` once no longer wanted.

### Why 221 worked and 222 did not — corrected diagnosis (2026-08-18)

Earlier text in this task said "the grant that permitted ruby has lapsed", implying a persistent rule
expired. **That is wrong.** The evidence says there was probably never a persistent rule for this
destination at all.

| Test | Result |
|---|---|
| `ruby` → github.com | **OK in 0.02 s** |
| `ruby` → api.appstoreconnect.apple.com | hangs the full connect timeout, `Errno::ETIMEDOUT` |
| `curl` → api.appstoreconnect.apple.com | 0.3 ms, HTTP 401 |

Ruby is **not** blocked — it has working rules and reaches github instantly. Only the Apple
destination lacks one. The failure mode is decisive: an explicit **deny** rule refuses immediately,
while this **hangs for precisely the connect timeout**. That is Little Snitch holding the connection
pending while it shows an interactive alert on the physical display, waiting for a human.

**Build 221 succeeded because the operator was at the machine to answer that alert** — which is why
its Certificates & Config stage took 7 s. Build 222 ran while the operator was AFK over SSH, so the
alert went unanswered and fastlane spent 51 min timing out.

Whatever was clicked on 2026-08-16 was "Once" or "Until Quit"; both die when the ruby process exits,
which happens at the end of every build. Every build has been prompting; the cost was invisible
because someone was always there to click.

Alternatives ruled out: Little Snitch 6.3.3 dated 2025-11-18 (no update); its Agent has run
continuously for 13 d 10 h (no restart); `/opt/homebrew/bin/ruby` symlink dates from Jul 16 (no
upgrade); `curl` proves the network is fine.

Also withdrawn: an earlier note here inferred rules were removed because the config file shrank ~36 KB
since 221. The size swings between 678 KB and 868 KB across ordinary days, so it tracks connection
statistics, not rule count. It proves nothing.

**Action when back at the machine:** create a **permanent** rule for
`/opt/homebrew/lib/ruby/gems/4.0.0/bin/fastlane` → `api.appstoreconnect.apple.com`. Clicking Allow
again unblocks this build and breaks the next one; only a persistent rule makes AFK builds possible.

### Second deploy attempt 2026-08-18 13:40 — same block, aborted early

Retried to test whether the block was transient. It is not.

Pre-flight probe, three consecutive attempts: `ruby` → `api.appstoreconnect.apple.com` failed at
**7.01 s, 7.04 s, 7.01 s** (`Errno::ETIMEDOUT`, i.e. exactly the connect timeout each time) while
`curl` to the same host returned HTTP 401 in 0.155 s. Deterministic, not intermittent.

The run was launched anyway to close one genuine gap in that probe: it invoked `/opt/homebrew/bin/ruby`
directly, whereas the build runs `fastlane`. If Little Snitch attributed rules to the *script* rather
than the interpreter, the two could have differed. **They do not.** The build reached:

```
Verifying that the certificate and profile are still valid on the Dev Portal...
Creating authorization token for App Store Connect API
Timeout received: 'Faraday::ConnectionFailed', 'Net::OpenTimeout'. Retrying (remaining: 4)...
```

Same wall, same point, from the real `fastlane` binary. Aborted at that event rather than repeating
the 78-minute failure; SIGTERM let the script's cleanup trap run, and its worktree was removed.

**Conclusion: the deploy cannot complete without physical access.** The probe is now a valid 20-second
stand-in for a 78-minute build — run it before any future AFK deploy attempt:

```
ruby -rsocket -e 'Socket.tcp("api.appstoreconnect.apple.com",443,connect_timeout:6){puts "OK"}'
```

## Handoff — resume 2026-08-19 evening

Everything is ready. `dev` at `3b5008641`. The only blocker is a GUI action.

### Do this, in order

1. **Little Snitch → Settings → Security**: enable "allow the command-line tool to make changes".
   Highest value — it is what makes future AFK sessions able to manage rules over SSH instead of
   deadlocking like this one did.
2. **Add a permanent rule**: `/opt/homebrew/bin/ruby` (the build runs it as
   `/opt/homebrew/lib/ruby/gems/4.0.0/bin/fastlane`) → `api.appstoreconnect.apple.com:443`,
   **Allow / Forever**. A ruby → github.com rule already exists; scope the new one to match.
   Broader (`ruby` → `*.apple.com:443`) is fine — fastlane hits other Apple hosts during upload.
3. **Verify in 20 s** before spending 78 min:
   ```
   ruby -rsocket -e 'Socket.tcp("api.appstoreconnect.apple.com",443,connect_timeout:6){puts "OK"}'
   ```
   `OK` → good. Hang + `Errno::ETIMEDOUT` → the rule is not matching; check whether Little Snitch
   catalogued the process as `fastlane` rather than `ruby`.
4. **Build**: `./ci/local-build.sh --include-untracked`

### Remote-access findings (2026-08-18), so this is not re-derived

- Screen Sharing **is** enabled and listening on `*:5900` (`ScreenSharingSubscriber`, pid 997).
  Reachable at `100.64.0.2` (Tailscale) or `192.168.0.134` (LAN).
- VNC connects but renders **black**. At diagnosis time the screen was locked
  (`locked-flag-present`, `/dev/console` owned by `root`) while the `charlie` GUI session was alive
  (`loginwindow` 616, `Dock` 1550/1605). Waking the display with `caffeinate -u` and blind-typing the
  password did **not** fix it — so the remaining suspect is the Screen Sharing daemon lacking
  **Screen Recording** permission, which is a GUI-only grant.
- The Little Snitch CLI cannot substitute: every useful subcommand needs root **and** the tool is
  fenced by the Settings → Security toggle above. Confirmed by `sudo littlesnitch export-model`
  returning the authorization error rather than a model.
- `osascript`/System Events is unavailable to this session (`AppleEvent timed out (-1712)`), so no GUI
  automation from the CLI either.

### State at handoff

Nine patches; `patch-test.sh` green; drift CLEAN; stacked assertions passing (TRIO-037 flags 2,
TRIO-043 1, TRIO-045 1, TRIO-041 3) and the G7SensorKit pin at `7232e55`. Both targets compile clean
(watchOS + iOS, signing disabled). Five tasks carry diverse codex `pass` reviews; TRIO-049's
review is `waived` by operator decision.

## SHIPPED 2026-08-20 — build 222

`trio-v0.8.4-222`, uploaded to TestFlight and recorded. Run total **12m 43s**, exit 0.
Branch: `origin/ci-build/trio-v0.8.4-222-localCI-20260819T225258Z`. Built from `dev` at `3b5008641`.

| Stage | Duration |
|---|---|
| Environment & Tool Validation | 0s |
| Worktree Setup | 30s |
| **Certificates & Config** | **8s** |
| Patch Application | 1s |
| Ruby Dependencies | 0s |
| Build IPA | 4m 10s |
| TestFlight Upload | 7m 22s |
| Record Release | 32s |

The certificate stage — 8s here, 7s on build 221, **51m 43s** on the blocked attempt — is the clean
confirmation that the Little Snitch rule was the entire problem. The operator added a permanent rule
for ruby → `api.appstoreconnect.apple.com` on 2026-08-19; the pre-flight probe returned `OK in 0.17s`
against two days of deterministic 7s timeouts.

Build IPA at 4m 10s matches 221's 4m 14s, so the archive is normal — this session's code compiled and
packaged cleanly in the real signed build, not only in the unsigned compile check.

### Contents

| Item | Task |
|---|---|
| Watch carbs reach HealthKit / Tidepool | TRIO-037 |
| mmol/L delta parity (round each operand) | TRIO-038 |
| Watch mapped algorithm-state name + `algorithm_state_raw` | TRIO-041 |
| ACK only after handling is durable | TRIO-043 |
| Delta from the history store, backfill counted | TRIO-045 |
| G7SensorKit resynced with upstream, pinned `7232e55` | TRIO-049 |

Known and deliberately shipped unfixed: TRIO-047 (patch 10 deletes patch 09's dedupe guard on the
no-replyHandler path — already live in 221, direction is duplicates not loss) and TRIO-042
(no replay consumer for failed watch error reports).

## Post-install verification 2026-08-20 06:14 UTC — build 222 healthy on both platforms

| build | platform | rows | first seen | last seen |
|---|---|---|---|---|
| **222** | ios | 869 | 05:46:46 | 06:14:32 |
| **222** | watchos | 171 | 06:09:19 | 06:14:32 |
| 221 | watchos | 74 | 06:06:51 | 06:07:10 |

Clean cutover: the watch's last 221 row is 06:07:10, its first 222 row 06:09:19, and both platforms
are logging concurrently.

**Errors: 6, all the pre-existing benign one** — the `settings/model.json` lookup that build 221 also
carried. No new error class on either platform.

Functional signal in the first 30 minutes: iOS G7 BLE stack active (`connect_called`, `attach_path`,
`auth_authenticated_bonded`, `egv_received`); watch emitting `watch_resident_sample`,
`complication_get_timeline_called`, `watch_wc_inbound`, and **`build205_w_history_insert` ×4** — the
TRIO-029 history store taking entries, which is the mechanism TRIO-045's delta fix depends on.

No `egv_unreliable` yet, so TRIO-041's mapped-state-name criterion still awaits a real state-18
event. That is expected, not a gap.
