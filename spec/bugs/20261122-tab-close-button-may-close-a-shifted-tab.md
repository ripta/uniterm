# A tab's close button may close a neighboring tab after the tabs shift

**Status:** fixed 2026-11-23
**Fixed:** 2026-11-23
**Estimate:** small; no open design decisions. The bar's index matches the applet's tabs at click time, since both
applets refresh the bar synchronously at every change. Only the hop before the close let the index go stale. So the fix
resolves the tab before the hop and leaves the shared bar contract alone. UTERM-053 M1 later swaps that index lookup
for an ID lookup.

## Observed

The user clicks a tab's close button. Before the close runs, other main-actor work removes or inserts a tab. The close
then acts on the tab now at the clicked index, which is a neighbor.

## Cause

- The browser's tab bar close action runs `Task { await closeTab(at: index) }`
  (`Packages/UnitermKit/Sources/BrowserApplet/BrowserApplet.swift`, about lines 252-254). The index resolves to a tab
  only when the task starts (about line 726).
- The terminal does the same (`Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift`, about lines 271-273).
- Work queued before the task can shift the tabs: a page's `window.close`, a pop-up insertion, a dispatched controller
  command, or a terminal tab whose process exits.

## Repro

Reproduced on 2026-11-23 in package tests for the browser and the terminal. The test fires the bar's close for tab 1 of
four, then closes tab 0 before the queued close runs. The neighbor that was at index 2 closed, and the clicked tab
stayed open. When the clicked tab was the last one, nothing closed, since the stale index then pointed past the end.

The questions applet closes synchronously from its bar, so it never had the bug.

## Fix

The browser's and the terminal's bar close actions now take the tab at the clicked index before their task hop. The
task then closes that tab wherever it sits. A tab that closed meanwhile is declined. The change is in
`Packages/UnitermKit/Sources/BrowserApplet/BrowserApplet.swift` and
`Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift`. The regression tests are
`testABarCloseClosesTheClickedTabAfterTheTabsShift` in `BrowserTabsTests` and `TerminalAppletTests`.

## Workarounds

Reopen the wrongly closed tab with the reopen command.
