# A focused pane whose applet ends on its own gives the keyboard to a neighbor

**Status:** open
**Estimate:** small, after a design call on where the keyboard goes
**Found:** 2026-11-16, while reviewing UTERM-026

## Observed

When the applet in the focused pane ends on its own, the pane closes and a neighbor pane takes the keyboard. Examples
are a terminal whose last session is ended by a background job or a signal, and a REPL whose VM ends. ADR-12 says that when an
unchosen close would move focus, the keyboard does not fall to a neighbor. Its context names "a run ends, and the pane
or tab it owned closes" as such a change. A user typing into the pane as it ends has the rest of their keys land in the
neighbor, which can be a shell.

Confirmed by tracing the code. No one has watched it in the running app. A shell the user ends with `exit` is a close
the user chose, so this bug covers only ends the user did not cause.

## Cause

`MainWindowController.appletDidExit` (`Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift:1414-1418`)
calls `closePane(_:appletEnded: true)`, which calls `describeAndClose` (`MainWindowController.swift:958`). That method
ends with `paneArea.focus(next, keyboard: !isPaletteVisible)` (`MainWindowController.swift:1083-1085`), so the neighbor
takes the keyboard. `discard` does the same at `MainWindowController.swift:1102-1104`.

## Repro

Split a terminal so two terminal panes sit side by side. In the focused one, run `(sleep 3; kill -HUP $$) &`, then keep
typing. The shell's own background job ends the session, so the user did not choose the close. A terminal whose last
session ends calls `appletDidExit` (`Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift:740-749`).

- Expected: the focus mark may move, but no pane takes the keyboard until the user clicks or moves focus.
- Actual: the neighbor terminal takes the keyboard, and the next keys run there.

## Fix

Call `focus(next, keyboard: false)` when the close comes from `appletDidExit`, and keep the keyboard path for closes the
user asked for. A test ends a focused pane's applet and checks that no neighbor's applet became first responder.

The design call is what the window shows and where keys go until the user chooses:

- The focus mark moves to the neighbor, and the window holds the keyboard with no pane taking keys. The first click or
  focus move arms a pane.
- The focus mark moves, and the neighbor takes keys only after a short pause. ADR-12 rejects a delay.

The same bug crosses windows. A window whose only pane's applet ends closes, through `closePane` and `closeLastPane`
(`MainWindowController.swift:947-953` and `:1123-1126`). AppKit then makes another window key, and that window's
focused pane takes the keyboard. The code path is traced. The AppKit key handoff is standard behavior, but no one has
traced it. UTERM-026 "Focus" settles that no pane in any window becomes first responder after such a close, so the fix
covers both cases.

Whether a shell ending on `exit` counts as chosen is part of the same call. Telling it apart from an end the user did
not cause may not be possible from the applet's exit alone.
