+++
uid = "019f8141-e117-77db-9216-aae0d79fa49d"
key = "TRIO-007"
title = "Fix FPU Nightscout upload bookkeeping + add isFPU/fpuID metadata (Trio)"
status = "ready"
kind = "code"
source = "human"
source_ref = "docs/in-progress/fpu-nightscout-reporting/fpu-nightscout-reporting-trio-impl-plan.md#L4"
created = 2026-07-20
updated = 2026-07-20
touched = 2026-07-20
owner = "me"
tags = ["nightscout", "fpu"]
+++

## Intent

Trio distinguishes meal entries from delayed fat/protein carb-equivalents (FPU) internally via
`isFPU`/`fpuID`, but both upload to Nightscout as `eventType: "Carb Correction"` with no
distinguishing metadata — Nightscout can't tell them apart. FPU delayed chunks also never get
marked uploaded, so they're re-uploaded every cycle (the one live, user-visible bug). Design A
(locked): preserve the shared FPU upload `id` (`= fpuID`, needed for one-call batch delete via
`deleteCarbs(withId:)`), add `isFPU`/`fpuID` metadata (additive — Nightscout upserts on
`created_at`+`eventType` and passes unknown fields through), and fix bookkeeping by matching FPU
rows on `fpuID` instead of `id`. No change to upload `id`, COB semantics, or Nightscout deletion.
Full plan: `docs/in-progress/fpu-nightscout-reporting/fpu-nightscout-reporting-trio-impl-plan.md`.
Investigation: `fpu-nightscout-reporting-investigation.md`.

A companion nightscout-nextjs task (to consume/formalize this metadata) is tracked separately in
the nightscout-nextjs repo, not here.

## Acceptance criteria

- [ ] `Trio/Sources/Models/NightscoutTreatment.swift` (and related upload path) adds `isFPU`/`fpuID` metadata to FPU delayed-chunk uploads
- [ ] Upload-status bookkeeping matches FPU rows on `fpuID` instead of shared `id`, so they're marked uploaded and stop re-uploading every cycle
- [ ] Upload `id`, COB semantics, and Nightscout deletion behavior unchanged
- [ ] Parent-meal uploads (`fat`/`protein` populated) unaffected
