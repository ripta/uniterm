# A pane a script opens with `uniterm/open-pane` takes keyboard focus

**Status:** fixed 2026-11-18
**Fixed:** 2026-11-18
**Estimate:** small; no open design decisions. ADR-12 settles the behavior, and the controller's `openPane` has one caller, `WindowSet.openPane`.
**Found:** 2026-11-16, while reviewing UTERM-026

## Observed

A script that calls `uniterm/open-pane` splits a pane, and the new pane takes keyboard focus. ADR-12 says a pane, tab,
or form that a program opens takes no focus, and focus stays where the user left it. A user typing in the terminal
the script runs from has their next keys land in the new pane.

Confirmed by tracing the code. No one has watched it in the running app.

Reproduced 2026-11-18 with a throwaway test. It opened a pane through the scripting fixture's `openPane` and compared `focusedPane` before and after. The focused pane changed to the new pane.

## Cause

`WindowSet.openPane` (`Packages/UnitermKit/Sources/WindowKit/WindowScripting.swift:178-181`) calls
`MainWindowController.openPane(_:typeID:axis:from:directory:owner:access:)`. That method ends with
`paneArea.focus(created)` (`Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift:775`). The
`keyboard` argument defaults to true (`Packages/UnitermKit/Sources/WindowKit/PaneAreaView.swift:267`), so the new
pane's applet takes the keyboard.

The layout request path keeps focus where it was, as ADR-12 requires. Only the single-pane open moves it.

## Repro

Enable remote control on a terminal pane. In it, run a script that calls `(uniterm/open-pane :text-viewer)`, and keep
typing in the terminal while the call lands.

- Expected: the new pane opens beside the terminal, and focus stays in the terminal.
- Actual: the new pane is focused, and the next keys go to it.

## Fix

Drop the `paneArea.focus(created)` call from the controller's `openPane`. The user's own split paths call `focus`
themselves, so they keep moving focus to the pane the user made. Add a test that opens a pane through
`WindowSet.openPane` and checks that the focused pane and the first responder did not change. ADR-12 settles the
behavior, so no design call is needed.

## Fix note

The controller's scripted `openPane` no longer calls `paneArea.focus(created)`. A pane a script opens leaves the focused pane and the keyboard where they were. The user-driven split paths still focus the new pane. `testAScriptOpenedPaneTakesNoFocus` in `WindowScriptingTests.swift` pins it. It checks the focused pane and the new applet's focus count, not a real window's first responder.
