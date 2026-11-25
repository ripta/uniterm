# A tab's close button may close a neighboring tab after the tabs shift

**Status:** open
**Validation:** not confirmed; traced by reading the code during the UTERM-053 review. Not reproduced.

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

None run. Suggested: a package test queues a tab removal on the main actor, then fires the bar's close for a later
index before the queued work runs. Expected: the clicked tab closes. Suspected actual: its neighbor closes.

## Fix

Carry the tab's ID through the close action, and resolve it when the close runs. UTERM-053 proposes the same for a
windowed bar's reused items. The impact is low: a closed tab can be reopened, and a tab with unsent input asks first.

## Workarounds

Reopen the wrongly closed tab with the reopen command.
