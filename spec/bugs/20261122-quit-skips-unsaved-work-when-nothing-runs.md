# Quitting loses unsaved work when nothing is running

**Status:** fixed 2026-11-23
**Fixed:** 2026-11-23
**Estimate:** small; no open design decisions. Traced the code path, did not run it. The fix removes the `runningTabLabels` check from `applicationShouldTerminate` and keeps only the `windowSet` guard, so `WindowSet.shouldQuit()` owns the rule. It already returns true at once when nothing is unsaved and nothing runs. The change is `App/AppDelegate.swift` plus one UI test, since the delegate is in the app target and no package test can drive it.

## Observed

A user edits pins in a map viewer and does not save. No tab is running anything: every terminal sits at an idle
prompt. The user presses Cmd-Q. The app quits at once without asking, and the pin edits are lost.

## Cause

- `applicationShouldTerminate` (`App/AppDelegate.swift`, about lines 683-698) returns `.terminateNow` when
  `windowSet.runningTabLabels` is empty. `WindowSet.shouldQuit()` never runs then.
- `shouldQuit()` is what asks about unsaved work (`Packages/UnitermKit/Sources/WindowKit/WindowSet.swift`, about lines
  183-206). Its doc says it asks "before a quit that would lose unsaved work or end something running".
- The map reports nothing running (`MapViewerApplet.swift`, about line 26), so unsaved pins alone never reach the
  question.
- `UnsavedWorkTests` calls `shouldQuit()` directly, so it does not cover the delegate's guard.

## Repro

Open a map viewer, add a pin, and do not save. Leave every terminal at an idle prompt. Press Cmd-Q. Expected: the app
asks whether to save changes before quitting. Suspected actual: the app quits and the pin is gone.

## Fix

Let the delegate's guard pass to `shouldQuit()` when any window holds unsaved work, as well as when something runs. A
regression test drives the delegate, not `shouldQuit()` alone. No design call is known.

## Fix note

`applicationShouldTerminate` in `App/AppDelegate.swift` now guards only on the window set, so `WindowSet.shouldQuit()`
decides every quit. Cmd-Q with an edited map and nothing running now asks "Save changes before quitting?". A quit with
nothing to ask still ends at once.

Regression test: `MapViewerUITests.testQuittingAnEditedMapAsksEvenWhenNothingRuns`. Without the fix it failed with
"quitting an edited map asked nothing". With the fix, it and every UI class that presses Cmd-Q pass. That is 91 UI tests
in the Map, Data, Image, Text, Questions, Layout, and Terminal classes. The package suite passes too.
