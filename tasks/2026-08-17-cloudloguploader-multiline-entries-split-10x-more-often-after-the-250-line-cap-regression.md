+++
uid = "01a00ee7-e7b9-71b1-86b7-f97f25eb2cba"
key = "TRIO-040"
title = "CloudLogUploader: multiline entries split ~10x more often after the 250-line cap (regression)"
status = "review"
kind = "code"
source = "agent-discovered"
source_ref = "TRIO-032#known-limitation-2"
created = 2026-08-17
updated = 2026-10-16
touched = 2026-10-16
owner = "me"
tags = ["logging", "cloud-logging", "betterstack", "ios"]
parent = "01a14459-1abb-73ba-9248-679079504c8e"

[[acceptance]]
id = "AC-1"
text = "Cap applied at entry boundaries after aggregation, not at physical line count"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "commit"
evidence = "2ff4c78e5 — readCompleteLines no longer caps physical lines; uploadNewContent aggregates via CloudLogEntryAggregator.aggregateCapped(maxEntries: maxEventsPerRequest = 250)"
met_at = 2026-10-16
met_ts = "2026-10-16T19:11:42+02:00"
met_by = "unknown"
met_commit = "2ecbf86b007ee6649504fcfa2c48e1a35ffb9282"

[[acceptance]]
id = "AC-2"
text = "Offset arithmetic derived from `entry.utf8.count + 1` and asserted exact — no drift, no double-count, no skipped byte"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "commit"
evidence = "2ff4c78e5 — offsets come from raw byte counts (splitLines splits on 0x0A at byte level; consumedBytes = sum(rawBytes + 1) of returned lines), which equals entry.utf8.count + 1 for valid UTF-8 and stays exact for invalid bytes where the utf8 re-count drifted; readCompleteLines asserts byteCounts sum + count == completeData.count"
met_at = 2026-10-16
met_ts = "2026-10-16T19:11:42+02:00"
met_by = "unknown"
met_commit = "2ecbf86b007ee6649504fcfa2c48e1a35ffb9282"

[[acceptance]]
id = "AC-3"
text = "The >512 KB single-line-without-newline case still cannot re-read the same window forever (the bug found during [[TRIO-032]]); keep whatever guard currently prevents it"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "commit"
evidence = "2ff4c78e5 — the no-newline guard in readCompleteLines is unchanged (short read waits, full 512 KB window skips); cursor review 8582a832 confirmed it still cannot loop"
met_at = 2026-10-16
met_ts = "2026-10-16T19:11:43+02:00"
met_by = "unknown"
met_commit = "2ecbf86b007ee6649504fcfa2c48e1a35ffb9282"

[[acceptance]]
id = "AC-4"
text = "Progress remains unconditional under a transient failure — do not reintroduce the stall"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-09-26
evidence_kind = "commit"
evidence = "2ff4c78e5 — aggregateCapped returns >= 1 entry and > 0 consumed bytes for any non-empty line set; offset still saved only after every batch uploads (unchanged); cursor review 8582a832 checked both"
met_at = 2026-10-16
met_ts = "2026-10-16T19:11:43+02:00"
met_by = "unknown"
met_commit = "2ecbf86b007ee6649504fcfa2c48e1a35ffb9282"

[[acceptance]]
id = "AC-5"
text = "Tested against a real multi-line entry (a stack trace) spanning the cap boundary, asserting it arrives as one event"
owner = "operator"
phase = "pre-review"
state = "open"
added_at = 2026-09-26

[[sessions]]
host = "claude-code"
ref = "06b1609d-8bb6-4e3c-840b-16b24e177be9"
model_family = "claude"
started = 2026-10-16
role = "author"
started_at = "2026-10-16T17:11:39+00:00"

[[reviews]]
run_id = "8582a832-83ed-465c-92ae-52153f3ef07f"
model_family = "cursor"
verdict = "pass"
reviewed_commit = "47b993221c3ae0075030eeb62bbb1ccee1672db6"
reviewed_paths = ["Trio/Sources/Logger/CloudLogging/CloudLogEntryAggregator.swift", "Trio/Sources/Logger/CloudLogging/CloudLogUploader.swift", "TrioTests/CloudLogEntryAggregatorTests.swift"]
recorded_at = "2026-10-16T17:11:41+00:00"
+++

## Intent

Split out of [[TRIO-032]]'s "Known limitations, deliberately not fixed in 221" (limitation 2, rated
Medium). Recorded as its own task on 2026-08-17 so it does not leave the board when TRIO-032 is
accepted and archived.

**This is a regression introduced by TRIO-032's own fix**, which is why it is worth tracking rather
than filing as ordinary polish.

## The regression

The 221 fix bounds each pass to `maxEventsPerRequest` (250) **physical lines**. That cut can land
inside a multi-line entry — a stack trace, or a formatted table — splitting it across two Better
Stack events.

Before the fix, splits happened only at 512 KB read boundaries, roughly every ~2,700 lines. So the
change makes splitting roughly **10× more frequent**.

## The known fix, and why it was deferred

Cap at **entry** boundaries after aggregation rather than at physical lines. The arithmetic is exact:
`CloudLogEntryAggregator` joins with `"\n"`, so an entry's consumed byte length is precisely
`entry.utf8.count + 1`.

It was deferred because it moves offset computation into `uploadNewContent`, and offset arithmetic is
where two bugs already occurred during TRIO-032 (a >512 KB line with no newline re-reading the same
window forever; and a first fix that bounded the read without making progress unconditional, which
the first gpt-5.6-sol review correctly rated High). A wrong offset loses or duplicates logs, whereas a
split entry is cosmetic — so shipping the cosmetic regression was the right call under time pressure.
That trade does not need to stand permanently.

## Notes carried over from acceptance criteria

## What shipped

Commit 2ff4c78e5 on feature/cloud-logging, carried in patches/06-cloud-logging.patch for build 232 (TRIO-076). Each upload pass now splits the read window at the byte level, groups lines into entries, and stops after 250 entries, so the next pass always starts on an entry's first line. The offset advances by the exact raw bytes of the uploaded entries. That also fixes a latent drift: the old cap re-counted decoded strings, which overcounts any invalid UTF-8 byte. The over-long-line skip and the rule that the offset only moves after a successful upload are unchanged. Four new Swift Testing cases cover a stack trace across the cap, multi-byte and invalid UTF-8, no cap hit, and a window that starts mid-entry; running them is AC-5 (operator, since agents do not run xcodebuild). Cursor review 8582a832 passed with two medium notes not acted on: the per-pass decode cost is the same as before, and the uploader's offset wiring still has no direct test.

## Release note

Cloud logging: stack traces and other multi-line log entries now arrive in Better Stack as one event instead of being split in two.
