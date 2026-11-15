+++
uid = "01a1bd22-5fa8-7543-ba29-95050bc3f332"
key = "TRIO-106"
title = "Watch G7: acquisition-arm A/B on unmodified build 238 (arm off Nov 8-9, on Nov 9-10)"
status = "done"
kind = "docs"
source = "agent-start"
source_ref = "docs/in-progress/watch-g7-egv-capture/plan.md#W0"
created = 2026-11-08
updated = 2026-11-13
touched = 2026-11-13
closed = 2026-11-13
first_closed = 2026-11-13
accepted_by = "charlie"
accepted_at = 2026-11-13
accepted_ts = "2026-11-13T09:11:55+01:00"
tags = ["watch", "g7"]
parent = "01a1bd22-5e52-7284-a2e3-3b06fed3e6d9"
priority = 2

[[acceptance]]
id = "AC-1"
text = "Comparison report: arm-off vs arm-on windows stated exactly, live rate per ext_session_active stratum, session coverage, C5 share, longest gap, phone EGV/h guard, arm line counts"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "run"
evidence = "Comparison reports: scheduled runs trio-watch-acquisition-arm-ab-check (2026-11-10, session local_acf8e4d4) and trio-watch-acquisition-arm-third-day-check (2026-11-11, session local_4e17a553), plus a 2026-11-13 re-check over all arm-off data to 2026-11-13 05:05 UTC; windows, per-stratum live rates, coverage, C5, gaps, phone guard and arm line counts in the task body"
met_at = 2026-11-13
met_ts = "2026-11-13T09:06:51+01:00"
met_by = "claude-code"
met_commit = "25885059984491e789a927200cd2fd0d11a15f28"

[[acceptance]]
id = "AC-2"
text = "No [g7-watch] 'no pairing code ... not lodging' line in the arm-on window, and no phone EGV/h regression"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "query"
evidence = "BetterStack source 1659391, arm-on window 2026-11-09 11:47:43 -> 2026-11-10 11:47:43 UTC: 0 '[g7-watch] no pairing code' lines; phone egv_received 11.63/h vs 11.75, 11.88, 11.9, 11.9/h on the four arm-off days"
met_at = 2026-11-13
met_ts = "2026-11-13T09:06:52+01:00"
met_by = "claude-code"
met_commit = "25885059984491e789a927200cd2fd0d11a15f28"

[[acceptance]]
id = "AC-3"
text = "Operator decision recorded: keep the acquisition arm on or off"
owner = "operator"
phase = "pre-review"
state = "met"
added_at = 2026-11-08
evidence_kind = "operator"
evidence = "Operator in chat 2026-11-13, answering 'Keep the acquisition arm on?': 'Yes, keep it on'"
met_at = 2026-11-13
met_ts = "2026-11-13T09:10:22+01:00"
met_by = "charlie"
met_commit = "25885059984491e789a927200cd2fd0d11a15f28"

[[acceptance]]
id = "AC-4"
text = "Third day with the arm off (off-on-off, operator's choice 2026-11-10) compared against day 1 and day 2 within the session-off stratum; scheduled task trio-watch-acquisition-arm-third-day-check, 2026-11-11 20:00 CET"
owner = "agent"
phase = "pre-review"
state = "met"
added_at = 2026-11-10
evidence_kind = "run"
evidence = "Third-day run 2026-11-11 (session local_4e17a553) and 2026-11-13 re-check: session-off live rate arm on 142/236 = 60.2% vs arm off 41.6% (day 1), 52.6% (day 3 ex outage), 45.1% (day 4), 46.7% (day 5 partial); pooled off 358/768 = 46.6%"
met_at = 2026-11-13
met_ts = "2026-11-13T09:06:52+01:00"
met_by = "claude-code"
met_commit = "25885059984491e789a927200cd2fd0d11a15f28"
+++

## Intent

Plan docs/in-progress/watch-g7-egv-capture/plan.md W0. Arm off from 2026-11-08 11:00 UTC, on from about 2026-11-09 12:00 CET via the phone toggle plus a watch app relaunch, 24 h each, same sensor DXCMdA. Scheduled comparison trio-watch-acquisition-arm-ab-check runs 2026-11-10 15:00 CET and compares live rate within each ext_session_active stratum, because session coverage dominates raw totals. Decides whether the arm stays on, and so whether W5 is needed. No build ships until it reports.

## First comparison (2026-11-10 15:00 CET run)

Day 1 arm off (2026-11-08 11:47 → 2026-11-09 11:47 UTC) vs day 2 arm on (2026-11-09 11:47 → 2026-11-10 11:00 UTC). Session-off links delivered 69/166 = 41.6% vs 135/227 = 59.5%. Session-on links delivered 99.1% vs 97.6%, at their ceiling. Raw totals were equal (64.7% vs 65.4%) because only 16% of day-2 links were inside a session, against 40% on day 1. Phone 11.75 vs 11.61 EGV/h, no regression. There were no "no pairing code" lines, and 13 bootstrap stalls of 3-4 bursts each. Counts re-checked against BetterStack. Under the rule it is inconclusive, since only one stratum can move. The report is in the run session of the scheduled task trio-watch-acquisition-arm-ab-check.

Operator, 2026-11-10: "Third day, arm off". The arm goes off again on build 238 (phone toggle, then a watch app relaunch). The third-day comparison runs 2026-11-11 20:00 CET (scheduled task trio-watch-acquisition-arm-third-day-check). The W1 build waits for it, so the off day stays on 238.

## Re-check over all arm-off data (2026-11-13)

The arm stayed off from 2026-11-10 15:22:17 UTC. Build 238 and sensor DXCMdA held throughout. Windows run in 24 h blocks from that switch, to 2026-11-13 05:05 UTC. Day 3 leaves out the 16:19-22:15 UTC outage. Live rate on session-off links:

| Day | Arm | Session-off links live | Links in a session | Watch EGV/h | Longest watch gap | Phone EGV/h |
|---|---|---|---|---|---|---|
| 1 (Nov 8-9) | off | 69/166 = 41.6% | 40% | 7.5 | 45 min | 11.75 |
| 2 (Nov 9-10) | on | 142/236 = 60.2% | 15% | 7.6 | 40 min | 11.63 |
| 3 (Nov 10-11, ex outage) | off | 101/192 = 52.6% | 6% | 6.65 | 355 min with the outage | 11.88 |
| 4 (Nov 11-12) | off | 102/226 = 45.1% | 14% | 5.7 | 175 min | 11.9 |
| 5 (Nov 12-13, 13.7 h) | off | 86/184 = 46.7% | 0% | 6.3 | 40 min | 11.9 |

All arm-off days pooled: 358/768 = 46.6%, against 60.2% with the arm on. Day 4 is the best match for day 2, since sessions covered a similar share of links (14% vs 15%). On day 4 the arm-on day leads by 15 points on session-off links and by 13.5 points overall (52.3% vs 65.8%).

Day 4's 175 min gap (2026-11-11 22:59 to 2026-11-12 01:54 UTC) includes about 75 min (00:00-01:15 UTC) in which the watch app was alive but made no G7 connect at all. In those 75 min it logged complication background tasks and heartbeats, and no g7_core did_connect. Missed connects are what the arm's per-reading lodge prevents. The arm day had no gap over 40 min.
