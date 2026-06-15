# G7SensorKit upstream PR plan

**Version:** 0.1 (draft for Charlie review)
**Status:** In progress — Phase 3 of the upstream-packaging roadmap (G7SensorKit first)
**Created:** 2026-06-11 06:00 CEST
**Last updated:** 2026-06-11 07:51 CEST

**Audience:** LoopKit/G7SensorKit maintainers. **Evidence policy:** aggregate numbers only — no
raw logs, timestamps, or glucose values.

---

## Current state

- Fork (`cachrisman/G7SensorKit` `main` @ `cb216bd`) is **14 commits ahead / 3 behind**
  `LoopKit/G7SensorKit` `main`.
- Upstream's 3 new commits are translations-only + one `project.pbxproj` line — **the only file
  overlapping fork changes is `project.pbxproj`** (fork touched it for the watchOS target +
  `G7Telemetry.swift`). Rebase cost ≈ one small pbxproj conflict.
- The fork delta (b791cf5 → cb216bd, ~330 net insertions) is battle-tested: shipped in Trio
  builds 195–208, dual-platform telemetry throughout.

## The packaging problem

Fork commits interleave telemetry plumbing with fixes (e.g. the C-208 batch touches five files
across four concerns). Cherry-picking fork commits onto upstream produces incoherent PRs.
**Plan: rebuild surgical branches off `upstream/main`**, grouping by concern, with diffs that
match the shipped fork code as closely as possible (reviewers should be able to verify "this is
what's been running for months").

## Proposed PR sequence

### PR-A — watchOS platform support (pure additive, no iOS behavior change)

Branch: `upstream-pr/watchos-support` off `upstream/main`.

- watchOS framework target (from `28400c7`).
- `#if os(iOS)` gates on `G7CGMManager` / `G7CGMManagerState` / `G7DeviceStatus` and
  LoopKit-dependent members of the message types (from `39f39d8`); `import LoopKit` removed from
  `ExtendedVersionMessage` (unused — verified).
- pbxproj changes for the target (Charlie validates in Xcode; agents do not edit pbxproj per
  house rules).

**Pitch:** "Lets watchOS apps consume the library. Compile-time isolation only; the iOS surface
is bit-identical." Smallest possible reviewer ask; unlocks everything after it.

### PR-B — optional telemetry seam (additive, default no-op)

Branch: `upstream-pr/telemetry-seam` (based on PR-A).

- `G7Telemetry.swift`: lock-backed, set-once `emit` closure; serial dispatch; **zero overhead
  when unset** (single nil-check). From `0c4dcfd`/`6ab959d`/`e09dd23` + C-208-14.
- The `emitG7Telemetry(...)` call sites across `G7BluetoothManager` / `G7Sensor` /
  `G7PeripheralManager` (event names documented in the PR description), incl. `rescan_scheduled`
  (C-208-15).

**Pitch:** "The library's connection lifecycle is currently observable only via OSLog. This adds
a structured, host-pluggable seam that is a no-op by default. It is how every number in PR-C/D
was measured." Anticipated objection — "why telemetry in a BLE lib": answer is the no-op
default, the OSLog precedent already in the code, and the evidence it enabled.

### PR-C — thread-safety & reliability fixes (the credibility PR)

Branch: `upstream-pr/reliability-fixes` (based on PR-B so diffs match shipped fork code).

| Fix | Origin | Evidence (aggregate, dual-platform) |
|---|---|---|
| `G7GlucoseMessage` underflow guard (reject `age > messageTimestamp` instead of trapping) | C-208-18 | crash-trap in the BLE hot path; one corrupt 19-byte packet kills the process |
| `connectIfNotInFlight` dedup | `97388ef` | shipped since build 204; `connect_skipped` events confirm redundant connects occurred in the wild |
| didSet lock-order inversion fix (`queue.sync` → `queue.async`) | C-208-12 | stall proxies (`command_timeout` + `configure_block_skipped`) observed on **both** platforms (~9–29/day iOS, ~38–80/day watchOS) before the fix; before/after deltas available post-208 soak |
| `Locked<>`-backed `sensorID` / `activationDate` / `pendingAuth` / `needsVersionInfo` | C-208-13 | three-queue unsynchronized access demonstrable by inspection; minimal-diff fix (computed properties, call sites unchanged) |
| Config-retry exhaustion escalation + budget reset | C-208-11 + cb216bd | the dead-end state held zombie connections up to ~600s in earlier builds; escalation is fail-safe (state unreached in 30d on either platform once the cause was fixed) |
| `G7SensorDelegate` contract docs (first-discovery connect gap; `didDiscoverNewSensor` queue contract; `suspectedEndOfSession` heuristic semantics) | C-208-17 | the EOS heuristic measured **111/112 false-positive** on a per-window connection cadence — consumers must know |

**Pitch:** "Six small, independently-verifiable fixes to real defects, each with field evidence
from months of dual-platform production telemetry." This is the PR that builds trust.

### PR-D — behavioral improvements (discussion-first)

Open as an **issue describing the passive-observer/watchOS use case first**, PR after maintainer
signal. Contents if welcomed:

- C3 fail-closed `configureAndRun` + bounded retry (`3a0b2ac`) — highest-drift change; motivated
  by config-churn sessions; shared-path behavior change.
- C-207-2 fast-reconnect (0s pre-EGV / 2s post-EGV split, `40b5871`) — shared behavior change,
  deliberately gated on glucose-received rather than platform.
- Connection-event registration at `.poweredOn` + bound-peripheral handling (C-208-16 +
  cb216bd) — completes the wake path for hosts relying on system connection events.

**Rationale for deferring:** these change shared iOS behavior; leading with them invites the
hardest review first. After PR-C lands, the conversation has context and credibility.

## Pre-flight checklist (before opening PR-A)

1. Rebase the four PR branches onto current `upstream/main` (only conflict expected: pbxproj).
2. Run the G7SensorKit test target locally (Xcode; optionally with TSan — the fork builds
   standalone, outside the TestFlight pipeline constraint).
3. Verify PR-A builds for **both** platforms with no telemetry/fix content leaking in.
4. Sanity-pass each diff against the shipped fork code — divergences documented in the PR.
5. Scrub: no BetterStack references, no personal identifiers, aggregate numbers only.
6. Check upstream's contribution conventions (PR template, swiftformat config) and match.

## Open questions for Charlie

- PR-A and PR-B could be merged into one "watchOS support" PR if we judge the telemetry seam an
  easy sell — preference?
- GitHub issue first for PR-D, or hold D entirely until C lands?
- Who is the named maintainer-contact, if any (prior interactions with LoopKit reviewers)?

---

## Changelog

### v0.1 (2026-06-11)
- Initial draft: current state (14/3 vs upstream; pbxproj-only overlap), four-PR sequence
  (watchOS support → telemetry seam → reliability fixes → behavioral discussion), evidence
  table, pre-flight checklist.
