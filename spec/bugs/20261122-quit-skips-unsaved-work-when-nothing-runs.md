# Quitting loses unsaved work when nothing is running

**Status:** open
**Validation:** not confirmed in the app; found by reading the code during the UTERM-050 review. The trace is direct.

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
