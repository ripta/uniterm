# A tab a script opens with `uniterm/open-tab` takes the keyboard, against ADR-12

**Status:** open
**Estimate:** medium; one non-trivial decision, whether a scripted tab is selected. See Triage Notes.
**Found:** 2026-11-18, by the design critic reviewing the fix for a script-opened pane that took focus

## Observed

ADR-12 says a pane, tab, or form that a program opens takes no focus. A script's `open-tab` likely breaks that. The
applet that opens the tab ends by taking the keyboard. When the script's target pane is not the focused one, the focus
mark then follows the keyboard to that pane.

## Cause

- The script call reaches `opener.openTab(startingIn:)` in
  `Packages/UnitermKit/Sources/WindowKit/WindowScripting.swift:230`.
- The terminal's `openTab(startingIn:)` ends with an unconditional `focus()`
  (`TerminalApplet/TerminalApplet.swift:521`). That calls `makeFirstResponder`.
- The browser's `openTab(startingIn:)` calls `content.focusAddress()` (`BrowserApplet/BrowserApplet.swift` near 601).
- `PaneAreaView.followResponder` moves `focusedPane` to the pane that holds the first responder on the next window
  update (`WindowKit/PaneAreaView.swift:302-328`).

The user's own Cmd-T goes through the same `openTab` methods, and relies on that focus.

## Repro

Open two panes. Leave the keyboard in the first. From a script, call `open-tab` on the second pane.

- Expected: the keyboard and the focus mark stay in the first pane.
- Suspected: both move to the second pane.

## Fix

The tab opener needs to know whether the user chose the open. Name each design call:

- How the opener learns it: a `takesFocus` parameter on `openTab(startingIn:)`, as `RoutedOpenOptions` does for
  routed opens, or a separate scripted entry point.
- Whether a scripted tab is also selected. Selecting it changes what the pane shows. ADR-12 speaks of focus, not of
  selection, so this needs a call too.

## Triage Notes

Confirmed 2026-11-19 for the browser by a throwaway package test, since removed. It put the browser's content view in a
window, made another text field the first responder, and called `openTab(startingIn: nil)` through `TabOpening`, as
the script call does. The first responder moved to the address field's editor. The terminal path is traced in code
only. It ends in an unconditional `focus()`, and its tests run on a fake applet that never calls `focus()` from
`openTab()`, so they cannot see this.

The fix would touch `AppletKit/TabOpening.swift`, `TerminalApplet.swift`, `BrowserApplet.swift`, `WindowScripting.swift`,
and the `FakeApplet` tab-opening extension and `WindowScriptingTests.swift` for the regression test.

Design decisions:

- How the opener learns the open is unchosen. A `takesFocus` parameter follows `RoutedOpenOptions`. This one looks
  trivial, but the protocol method has the user's Cmd-T callers too.
- Whether a scripted tab is selected. This is non-trivial. ADR-12 says new content in a focused surface that a program
  changes is inert. A selected terminal tab in a focused pane would receive the user's next keys, so selecting it may
  itself break the ADR. Not selecting it changes what `open-tab` does for scripts.
