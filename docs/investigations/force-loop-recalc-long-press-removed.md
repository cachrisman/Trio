# Force-loop-recalculation long-press — what happened to it

**Version:** v1
**Created:** 2026-08-30
**Last updated:** 2026-08-30

---

## Summary

The long-press-to-force-a-loop-recalculation gesture on the loop status pill (top-right of the home
header) was removed **upstream**, not by anything in this fork's patch stack. It was replaced by a
pull-to-refresh gesture on the home dashboard. Whether a given build still has the long-press depends
on which branch/commit it was built from — see "Which branch has which behavior" below.

## Where the UI lived

`Trio/Sources/Modules/Home/View/HomeRootView.swift`, inside a `rightHeaderPanel()` view builder,
attached to the `LoopView` (the loop status circle):

```swift
LoopView(...)
    .onTapGesture { state.isLoopStatusPresented = true }
    .onLongPressGesture {
        let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
        impactHeavy.impactOccurred()
        state.runLoop()
    }
```

Call chain: `state.runLoop()` (`HomeStateModel.swift`) → `provider.heartbeatNow()`
(`HomeProvider.swift`) → `apsManager.heartbeat(date:)` (`APSManager.swift`), which nudges the
pump-heartbeat pipeline into starting a loop cycle.

## The commit that removed it

Found via `git log -S"state.runLoop()"` against `upstream/dev`:

- **Commit:** `f567bef7e` — "Add draggable chart with pinch zoom and pull-to-loop"
- **Author:** `dnzxy` (upstream `nightscout/Trio` contributor)
- **Date:** 2026-07-16
- Single-parent commit (not a merge), landed directly on upstream `dev`.
- Commit message states the intent explicitly: *"Pull the dashboard down to force a loop; replaces
  the loop pill long-press."*

Diff on the (now-split-out) header file:

```diff
             .onTapGesture {
                 state.isLoopStatusPresented = true
             }
-            .onLongPressGesture {
-                let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
-                impactHeavy.impactOccurred()
-                state.runLoop()
-            }
```

This was bundled into a large chart-rewrite PR (a custom pan/zoom canvas replacing the old scroll
view), so the loop-gesture change was incidental to a bigger chart refactor rather than a standalone
UX decision.

## Confirmed upstream, not a fork-patch effect

- `git merge-base --is-ancestor f567bef7e dev` → true (it's a real upstream `dev` commit).
- Grepped all patch files in both `Trio/patches/` and `Trio-dev/patches/` for `HomeRootView`,
  `LoopView`, `runLoop`, `forceLoop`, and long-press gestures — no patch touches this code. The only
  hit was an unrelated `RunLoop.main` reference in `13-phone-ble-observer-telemetry.patch`.

## What replaced it

A **pull-to-refresh gesture**, added in the same commit (new file
`Trio/Sources/Modules/Home/View/HomeRootView+Refresh.swift`): pulling the dashboard down past a
threshold calls `forceLoop()` → `state.runLoop()`, showing a "Pull down to force loop" hint while
dragging and a "Forcing loop…" spinner while the loop runs. Functionally equivalent trigger, different
gesture and affordance.

## Which branch has which behavior

This fork carries several branches/worktrees, and they aren't all at the same point relative to
`f567bef7e`:

- **Fork `dev`** (as of the 2026-08-30 upstream sync, see [[TRIO-050]]): long-press is **gone**,
  replaced by pull-to-refresh, per the above.
- **`Trio` worktree's feature branches** (e.g. `feature/cloud-logging`, as observed 2026-08-16): still
  had the old long-press code, because those branches hadn't yet merged this range of upstream `dev`.

Whichever branch actually produced the build the user is running determines which behavior they see.
If a shipped build still exhibits the long-press, it was built before this branch incorporated
`f567bef7e`; if it exhibits pull-to-refresh instead, it has.

## Related

- [[TRIO-050]] — the 2026-08-30 upstream sync that brought fork `dev` fully current, including this
  range of commits.
